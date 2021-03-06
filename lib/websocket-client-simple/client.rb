module WebSocket
  module Client
    module Simple

      def self.connect(url, options={})
        client = ::WebSocket::Client::Simple::Client.new
        yield client if block_given?
        client.connect url, options
        return client
      end

      class Client
        include EventEmitter
        attr_reader :url, :handshake

        def connect(url, options={})
          return if @socket
          @url = url
          uri = URI.parse url
          @socket = TCPSocket.new(uri.host,
                                  uri.port || (uri.scheme == 'wss' ? 443 : 80))
          if ['https', 'wss'].include? uri.scheme
            ctx = OpenSSL::SSL::SSLContext.new
            ctx.ssl_version = options[:ssl_version] || 'SSLv23'
            ctx.verify_mode = options[:verify_mode] || OpenSSL::SSL::VERIFY_NONE #use VERIFY_PEER for verification
            ctx.cert_store  = options[:cert_store]  || cert_store
            ctx.cert = cert_chain_file(options[:cert_chain_file])
            ctx.key = private_key_file(options[:private_key_file])
            @socket = ::OpenSSL::SSL::SSLSocket.new(@socket, ctx)
            @socket.connect
          end
          @handshake = ::WebSocket::Handshake::Client.new :url => url, :headers => options[:headers]
          @handshaked = false
          @pipe_broken = false
          frame = ::WebSocket::Frame::Incoming::Client.new
          @closed = false
          once :__close do |err|
            close
            emit :close, err
          end

          @thread = Thread.new do
            while !@closed do
              begin
                unless recv_data = @socket.getc
                  sleep 1
                  next
                end
                unless @handshaked
                  @handshake << recv_data
                  if @handshake.finished?
                    @handshaked = true
                    emit :open
                  end
                else
                  frame << recv_data
                  while msg = frame.next
                    emit :message, msg
                  end
                end
              rescue => e
                emit :error, e
              end
            end
          end

          @socket.write @handshake.to_s
        end

        def send(data, opt={:type => :text})
          return if !@handshaked or @closed
          type = opt[:type]
          frame = ::WebSocket::Frame::Outgoing::Client.new(:data => data, :type => type, :version => @handshake.version)
          begin
            @socket.write frame.to_s
          rescue Errno::EPIPE => e
            @pipe_broken = true
            emit :__close, e
          end
        end

        def close
          return if @closed
          if !@pipe_broken
            send nil, :type => :close
          end
          @closed = true
          @socket.close if @socket
          @socket = nil
          emit :__close
          Thread.kill @thread if @thread
        end

        def open?
          @handshake.finished? and !@closed
        end

        private

        def cert_store
          cert_store = OpenSSL::X509::Store.new
          cert_store.set_default_paths
        end

        def cert_chain_file(cert_chain_file_path)
          return unless cert_chain_file_path.nil?
          raise "Certificate file not found" unless File.exists?(cert_chain_file_path)

          OpenSSL::X509::Certificate.new(File.read(cert_chain_file_path))
        end

        def private_key_file(private_key_file_path)
          return unless private_key_file_path.nil?
          raise "Private Key file not found" unless File.exists?(private_key_file_path)

          OpenSSL::X509::Certificate.new(File.read(private_key_file_path))
        end

      end

    end
  end
end
