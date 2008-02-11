# Ruby module to interact with the SAPO Broker
# Author: Andr� Cruz <andre.cruz@co.sapo.pt>

# WARNING: This API is NOT threadsafe!
# PRODUCER EXAMPLE:
# require 'SAPOBroker'

# client = SAPOBroker::Client.new(["10.135.5.110:2222"])

# 10000.times do |i|
#   msg = SAPOBroker::Message.new
#   msg.destination = '/blogoscopio/test'
#   msg.payload = "Message N. %i" % i
#   client.enqueue(msg)
# end

# CONSUMER EXAMPLE:
# require 'SAPOBroker'

# client = SAPOBroker::Client.new(["10.135.5.110:2222"])
# client.subscribe('/blogoscopio/test', 'QUEUE')

# 10000.times do |i|
#   msg = client.receive
# end

# ASYNC CONSUMER EXAMPLE:
# require 'SAPOBroker'

# client = SAPOBroker::Client.new(["10.135.5.110:2222"])
# client.subscribe('/blogoscopio/test', 'QUEUE')

# thr = client.receive do |msg|
#     puts msg.payload
#   end
# # Go on with your life
# thr.join

module SAPOBroker

  require 'socket'
  require 'rexml/document'

  class Message
    attr_accessor(:destination, :payload, :id, :correlation_id, :timestamp, :expiration, :priority)

    def xml_escape(text)
      t = REXML::Text.new('')
      str = ''
      t.write_with_substitution(str, text)
      str
    end

    def to_xml()
      # return xml representation of broker message
      message = ""
      message << '<BrokerMessage>'
      message << "<DestinationName>#{self.destination}</DestinationName>"
      message << "<TextPayload>#{xml_escape(self.payload)}</TextPayload>"
      message << "<Priority>#{self.priority}</Priority>" if self.priority
      message << "<MessageId>#{self.id}</MessageId>" if self.id
      message << "<Timestamp>#{self.timestamp}</Timestamp>" if self.timestamp
      message << "<Expiration>#{self.expiration}</Expiration>" if self.expiration
      message << "<CorrelationId>#{self.correlation_id}</CorrelationId>" if self.correlation_id
      message << '</BrokerMessage>'
    end
    
    def from_xml(xml)
      doc = REXML::Document.new(xml)
      REXML::XPath.each(doc, "//mq:BrokerMessage/*", {'mq' => 'http://services.sapo.pt/broker'}) do |elem|
        case elem.name
        when 'Priority' then self.priority = elem.text
        when 'MessageId' then self.id = elem.text
        when 'Timestamp' then self.timestamp = elem.text
        when 'Expiration' then self.expiration = elem.text
        when 'DestinationName' then self.destination = elem.text
        when 'TextPayload' then self.payload = elem.text
        when 'CorrelationId' then self.correlation_id = elem.text
        end
      end
      self
    end

  end
  
  class Client
    
    def disconnect
      @sock.close
    end

    def subscribe(dest_name, type = 'QUEUE', ack_mode = 'AUTO')
      sub_msg = <<END_SUB
<soapenv:Envelope xmlns:soapenv='http://www.w3.org/2003/05/soap-envelope'><soapenv:Body>
<Notify xmlns='http://services.sapo.pt/broker'>
<DestinationName>#{dest_name}</DestinationName>
<DestinationType>#{type}</DestinationType>
</Notify>
</soapenv:Body></soapenv:Envelope>
END_SUB

      sub_msg = [sub_msg.length].pack('N') + sub_msg
      @sock.write(sub_msg)

      @sub_map[dest_name] = {:type => type, :ack_mode => ack_mode} unless @sub_map.has_key?(dest_name)
    end

    def ack(message)
      ack_msg = <<END_ACK
<soapenv:Envelope xmlns:soapenv="http://www.w3.org/2003/05/soap-envelope"><soapenv:Body>
<Acknowledge xmlns="http://services.sapo.pt/broker">
<MessageId>#{message.id}</MessageId>
<DestinationName>#{message.destination}</DestinationName>
</Acknowledge>
</soapenv:Body></soapenv:Envelope>
END_ACK
      ack_msg = [ack_msg.length].pack('N') + ack_msg
      @sock.write(ack_msg)
    end

    def enqueue(message)
      send_event('Enqueue', message)
    end

    def publish(message)
      send_event('Publish', message)
    end

    def receive
      if block_given?
        # we want assynchronous behaviour
        Thread.new do
          loop do
            yield _receive
          end
        end
      else
        _receive
      end
    end

    private
    def initialize(server_list, logger = nil)
      
      if logger
        @logger = logger
      else
        require 'logger'
        @logger = Logger.new(STDOUT)
      end

      @sub_map = {}

      @server_list = server_list
      reconnect()

    end

    def _receive
      catch(:retry) do
        msg_len = @sock.recv(4).unpack('N')[0]
        throw(:retry) if sick_socket?(msg_len)
        @logger.debug("Will receive message of %i bytes" % msg_len)
        
        xml = @sock.recv(msg_len)
        @logger.debug("Got message %s" % xml)
        message = Message.new.from_xml(xml)
        ack(message) if @sub_map.has_key?(message.destination) && 
          @sub_map[message.destination][:type] == 'QUEUE' &&
          @sub_map[message.destination][:ack_mode] == 'AUTO'
        message
      end
    end

    def reconnect
      @server_list.sort_by {rand}.each do |server|
        host, port = server.split(/:/)
        begin
          @logger.debug("Trying #{host} on port #{port}")
          @sock = TCPSocket.new(host, port)
          @logger.debug("Connected to #{host} on port #{port}")
          @sub_map.each_pair do |destination, params|
            @logger.debug("Re-subscribing to #{destination}")
            subscribe(destination, params[:type], params[:ack_mode])
            @logger.debug("Subscribed to to #{destination}")
          end
          return
        rescue Errno::ECONNREFUSED => ex
          @logger.warn("Problems (#{server}): " + ex.message)
        end
      end

      raise IOError, "All servers are down"
    end

    def send_event(msg_type, message)
      evt_msg = <<END_EVT
<soapenv:Envelope xmlns:soapenv="http://www.w3.org/2003/05/soap-envelope"><soapenv:Body>
<#{msg_type} xmlns="http://services.sapo.pt/broker">
#{message.to_xml}
</#{msg_type}>
</soapenv:Body></soapenv:Envelope>
END_EVT
      
      evt_msg = [evt_msg.length].pack('N') + evt_msg
      @sock.write(evt_msg)
    end

    def sick_socket?(len)
      if len == 0 && (@sock.closed? || @sock.eof?) then
        reconnect
        true
      else
        false
      end
    end
    
  end

end