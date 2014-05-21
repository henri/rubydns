# Copyright, 2009, 2012, by Samuel G. D. Williams. <http://www.codeotaku.com>
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

require_relative 'message'
require_relative 'binary_string'

module RubyDNS
	# Handling incoming UDP requests, which are single data packets, and pass them on to the given server.
	class UDPHandler
		include Celluloid::IO
		
		def initialize(server, host, port)
			@socket = UDPSocket.new
			@socket.bind(host, port)
			
			@server = server
			
			@logger = @server.logger || Celuloid.logger
			
			async.run
		end
		
		def run
			loop { handle_connection }
		end
		
		def process_query(data, options)
			@logger.debug "Receiving incoming query (#{data.bytesize} bytes)..."
			query = nil

			begin
				query = RubyDNS::decode_message(data)

				return @server.process_query(query, options)
			rescue => error
				@logger.error "Error processing request!"
				@logger.error "#{error.class}: #{error.message}"

				error.backtrace.each { |line| @logger.error line }

				# Encoding may fail, so we need to handle this particular case:
				server_failure = Resolv::DNS::Message::new(query ? query.id : 0)
				server_failure.qr = 1
				server_failure.opcode = query ? query.opcode : 0
				server_failure.aa = 1
				server_failure.rd = 0
				server_failure.ra = 0

				server_failure.rcode = Resolv::DNS::RCode::ServFail

				# We can't do anything at this point...
				return server_failure
			end
		end
		
		def handle_connection
			@logger.debug "Waiting for incoming UDP packet #{@socket.inspect}..."
			
			input_data, (_, remote_port, remote_host) = @socket.recvfrom(UDP_TRUNCATION_SIZE)
			
			@logger.debug "Got incoming packet of size #{input_data.size} bytes..."
			
			options = {peer: remote_host}
			
			answer = process_query(input_data, options)
			
			output_data = answer.encode
			
			@logger.debug "Writing response to client (#{output_data.bytesize} bytes) via UDP..."
			
			if output_data.bytesize > UDP_TRUNCATION_SIZE
				@logger.warn "Response via UDP was larger than #{UDP_TRUNCATION_SIZE}!"
				
				# Reencode data with truncation flag marked as true:
				truncation_error = Resolv::DNS::Message.new(answer.id)
				truncation_error.tc = 1
				
				output_data = truncation_error.encode
			end
			
			@socket.send(output_data, 0, remote_host, remote_port)
		rescue => error
			puts error.inspect
			raise
		end
	end
	
	class TCPHandler < UDPHandler
		def run
			loop { async.handle_connection @socket.accept }
		end
		
		def handle_connection(socket)
			_, port, host = socket.peeraddr
			options = {peer: host}
			
			buffer = BinaryStringIO.new
			length = 2
			processed = 0
			
			while (buffer.size - processed) < length
				data = socket.read(UDP_TRUNCATION_SIZE)
				
				buffer.write(data)
				
				if buffer.size >= 2
					length = buffer.string.byteslice(@processed, 2).unpack('n')[0]
					processed += 2
				end
			end
			
			data = buffer.string.byteslice(@processed, @length)
			
			answer = self.process_query(@server, data, options)
			
			send_response(socket, answer)
		ensure
			socket.close
		end
	end
end
