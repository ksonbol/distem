module Daemon

require 'resolv'
require 'pnode'
require 'vnode'

class Ressource
  def initialize()
    @pnodes = {}
    @vnodes = []
  end

  def add_vnode(vnode)
    raise unless vnode.is_a?(VNode)

    @pnodes[vnode.host.address] = vnode.host \
      unless @pnodes.has_key?(vnode.host.address)
    @vnodes << vnode
  end

  def get_pnode(address)
    # >>> TODO: validate ip address
    if @pnodes.has_key?(address)
      ret = @pnodes[address]
    else
      ret = PNode.new(address)
    end

    return ret
  end
end

end
