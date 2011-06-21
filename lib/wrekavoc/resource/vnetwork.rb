require 'wrekavoc'
require 'ipaddress'

module Wrekavoc
  module Resource

    class VNetwork
      attr_reader :address, :name, :vnodes, :vroutes
      @@id = 0
      @@alreadyusedaddr = Array.new

      #address = ip/mask or ip/cidr
      def initialize(address,name="")
        name = "vnetwork#{@@id}" if name.empty?
        @name = name
        if address.is_a?(IPAddress)
          @address = address.network
        else
          begin
            @address = IPAddress.parse(address).network
          rescue ArgumentError
            raise Lib::InvalidParameterError, address
          end
        end
        @vnodes = {}
        @vroutes = {}

        @curaddress = @address.first
        @@id += 1
      end 

      def add_vnode(vnode,viface,address=nil)
        #Atm one VNode can only be attached one time to a VNetwork
        raise Lib::AlreadyExistingResourceError, vnode.name if @vnodes[vnode]

        addr = nil
        if address
          begin
            address = IPAddress.parse(address) unless address.is_a?(IPAddress)
            address.prefix = @address.prefix.to_i
          rescue ArgumentError
            raise Lib::InvalidParameterError, address
          end
          raise Lib::InvalidParameterError, address.to_s \
            unless @address.include?(address)

          raise Lib::UnavailableResourceError, address.to_s \
            if @@alreadyusedaddr.include?(address.to_s)

          addr = address.clone
        else
          inc_curaddress() if @@alreadyusedaddr.include?(@curaddress.to_s)
          addr = @curaddress.clone
          inc_curaddress()
        end

        @vnodes[vnode] = viface
        @@alreadyusedaddr << addr.to_s
        viface.attach(self,addr)
      end

      def remove_vnode(vnode)
        #Atm one VNode can only be attached one time to a VNetwork
        @vnodes[vnode].detach(self) if @vnodes[vnode]
        @vnodes[vnode] = nil
      end

      def add_vroute(vroute)
        #Replace the route if it already exists
        raise unless vroute.dstnet
        @vroutes[vroute.dstnet] = vroute
      end

      def get_list
        ret = ""
        @vnodes.each do |vnode,viface|
          ret = "#{vnode.name}(#{viface.name}) #{viface.address.to_s}\n"
        end
        return ret
      end

      def get_vroute(vnetwork,excludelist=[])
        ret = nil
        excludelist << self
        found = false

        vnodes.each_key do |vnode|
          vnode.vifaces.each do |viface|
            found = true if viface.connected_to?(vnetwork)

            unless excludelist.include?(viface.vnetwork)
              found = true if viface.vnetwork.get_vroute(vnetwork,excludelist) 
            end

            break if found
          end

          if found
            ret = vnode
            break
          end
        end

        excludelist.delete(self)

        return ret
      end

      def ==(vnetwork)
        return ((vnetwork.is_a?(VNetwork)) and (vnetwork.address.to_string == @address.to_string))
      end

      def to_hash()
        ret = {}
        ret['name'] = @name
        ret['address'] = @address.to_string
        return ret
      end

      protected
      def inc_curaddress
        tmp = @curaddress.u32
        begin
          tmp += 1
          tmpaddr = IPAddress::IPv4.parse_u32(tmp,@curaddress.prefix)
          raise Lib::UnavailableRessourceError, "IP/#{@name}" \
            if tmpaddr == @address.last
        end while @@alreadyusedaddr.include?(tmpaddr.to_s)
        @curaddress = tmpaddr
      end
    end

  end
end
