
#!/usr/bin/ruby
# Experimental test suite for Distem
# - supposed to be executed inside an OAR reservation with KaVLAN
# - netssh and netssh/multi gems must be installed


require 'tempfile'
require 'yaml'
require 'pp'
require 'rubygems'
require 'minitest/autorun'
require 'net/ssh'
require 'net/ssh/multi'

DISTEMROOT = ARGV[0]

ROOT= "/tmp/distem/test/experimental_testing"
USER = "root"
GIT = (ARGV[1] == 'true')
CLUSTER = ARGV[2]
IMAGE_FRONTEND = '/home/amerlin/public/distem-test-img.tgz'
IMAGE = '/tmp/distem-test-img.tgz'
REFFILE = "#{DISTEMROOT}/test/experimental_testing/ref_#{CLUSTER}.yml"
MIN_PNODES = 2
DISTEMBOOTSTRAP = "/grid5000/code/bin/distem-bootstrap"
NET = ARGV[3]
NODES = ARGV[4].split(',')


module Kernel
private
  def this_method
    caller[0] =~ /`([^']*)'/ and $1
  end
end

class CommonTools
  def CommonTools::error(str)
    puts "# ERROR: #{str}"
    exit 1
  end

  def CommonTools::msg(str)
    puts "# #{str}"
    STDOUT.flush
  end

  def CommonTools::reboot_nodes(pnodes)
    nb_rebooted_nodes = nil
    10.times.each { |i|
      msg("Rebooting #{pnodes.join(',')} (attempt #{i+1})")
      ok = Tempfile.new("nodes_ok")
      node_list = "-m #{pnodes.join(' -m ')}"
      system("kareboot3 -V 1 -r simple #{node_list} -o #{ok.path}")
      next if not File.exist?(ok.path)
      nb_rebooted_nodes = IO.readlines(ok.path).length
      break if (nb_rebooted_nodes == pnodes.length)
    }
    return (nb_rebooted_nodes == pnodes.length)
  end

  def CommonTools::deploy_nodes(pnodes, environment)
    deployed_pnodes = nil
    10.times.each { |i|
      msg("Deploying #{pnodes.join(',')} (attempt #{i+1})")
      ok = Tempfile.new("nodes_ok")
      node_list = "-m #{pnodes.join(' -m ')}"
      system("kadeploy3 -V 1 #{node_list} -e #{environment} -u deploy -k -o #{ok.path}")
      next if not File.exist?(ok.path)
      deployed_pnodes = IO.readlines(ok.path).collect { |line| line.strip }
      break if (deployed_pnodes.length == pnodes.length)
    }
    return deployed_pnodes
  end

  def CommonTools::clean_nodes(pnodes)
    msg("Cleaning #{pnodes.join(',')}")
    Net::SSH::Multi.start { |session|
      pnodes.uniq.each { |pnode|
        session.use("root@#{pnode}")
      }
      session.exec('rm -rf /tmp/distem')
      session.loop
    }
  end
end

class ExperimentalTesting < MiniTest::Test
  @@initialized = false
  @@coordinator = nil
  @@pnodes = nil
  @@deployed_nodes = nil
  @@ref = nil

  def self.test_order
    :alpha
  end

  def plateform_init
    @@ref = YAML::load_file(REFFILE)
    if !NODES.empty? and !NET.empty?
      nodes = NODES
      subnet = NET
    else
      CommonTools::error("This script must be run inside an OAR reservation or the nodes and subnet must explicitly be set") if not ENV['OAR_JOB_ID']
      subnet = `g5k-subnets -p`.strip
      CommonTools::error("No ip subnet reserved") if subnet.empty?
      nodes = IO.readlines(ENV['OAR_NODE_FILE']).collect { |line| line.strip }.uniq
      CommonTools::error("Not enough nodes") if nodes.length < MIN_PNODES
    end
    nodes.each do |n|
      `scp -o StrictHostKeyChecking=no #{IMAGE_FRONTEND} #{USER}@#{n}:#{IMAGE}`
    end
    @@coordinator = nodes.first
    @@pnodes = nodes
    @@subnet = subnet

    @@initialized = true
  end

  def clean_env
#    CommonTools::reboot_nodes(@@deployed_nodes, @@vlan) if MODE == 'g5k'
    CommonTools::clean_nodes(@@pnodes)
  end

  def check_result(str)
    assert(str.include?("TEST PASSED"), str)
  end

  def install_distem(extra_params = "")
    f = Tempfile.new("distemnodes")
    @@pnodes.uniq.each { |pnode|
      f.puts(pnode)
    }
    f.close
    distemcmd = "#{DISTEMBOOTSTRAP} -c #{@@coordinator} -f #{f.path} --enable-admin-network"
    distemcmd += ' -g -U https://github.com/alxmerlin/distem.git' if GIT
    distemcmd += " --max-vifaces 250 -r net-ssh-multi #{extra_params}"
    system(distemcmd)
  end

  def launch_vnodes(ssh, opts)
    pf_kind = opts['pf_kind']
    return false if not pf_kind
    pnodes = opts['pnodes'] if opts['pnodes']
    cli = opts['cli'] ? opts['cli'] : false

    case pf_kind
    when '1node_cpu'
      if cli
        return false
      else
        return ssh_exec(ssh, "ruby #{File.join(ROOT,'platforms/distem_platform_1node-api.rb')} #{@@subnet} /tmp/ip #{IMAGE}")
      end
    when '1node_def'
      # It will create the definition and it wont start the vnode
      if cli
        return false
      else
        return ssh_exec(ssh, "ruby #{File.join(ROOT,'platforms/distem_platform_1node-def.rb')} #{@@subnet} /tmp/ip #{IMAGE}")
      end
    when '2nodes'
      if cli
        return ssh_exec(ssh, "ruby #{File.join(ROOT,'platforms/distem_platform_2nodes-cli.rb')} #{@@subnet} #{pnodes[0]},#{pnodes[1]} /tmp/ip #{IMAGE}")
      else
        return ssh_exec(ssh, "ruby #{File.join(ROOT,'platforms/distem_platform_2nodes-api.rb')} #{@@subnet} #{pnodes[0]},#{pnodes[1]} /tmp/ip #{IMAGE}")
      end
    when '50nodes'
      if cli
        return false
      else
        return ssh_exec(ssh, "ruby #{File.join(ROOT,'platforms/distem_platform_50nodes-api.rb')} #{@@subnet} /tmp/ip #{IMAGE}")
      end
    when '200nodes'
      if cli
        return false
      else
        return ssh_exec(ssh, "ruby #{File.join(ROOT,'platforms/distem_platform_200nodes-api.rb')} #{@@subnet} /tmp/ip #{IMAGE}")
      end
    else
      raise "Invalid platform kind"
    end
  end

  def ssh_exec(ssh, command)
    stdout_data = ''
    stderr_data = ''
    exit_code = nil
    exit_signal = nil
    ssh.open_channel do |channel|
      channel.exec(command) do |ch, success|
        unless success
          abort "FAILED: couldn't execute command (ssh.channel.exec)"
        end
        channel.on_data do |ch, data|
          stdout_data += data
        end

        channel.on_extended_data do |ch, type, data|
          stderr_data += data
        end

        channel.on_request("exit-status") do |ch, data|
          exit_code = data.read_long
        end

        channel.on_request("exit-signal") do |ch, data|
          exit_signal = data.read_long
        end
      end
    end
    ssh.loop
    [stdout_data, stderr_data, exit_code, exit_signal]
  end

  def setup
    plateform_init if not @@initialized
    clean_env
  end

  def teardown
    Net::SSH.start(@@coordinator, USER) { |session|
      session.exec!('distem -q')
    }
  end
  ##############################
  #####   Tests start here #####
  ##############################

  def test_00_setup_ok
    install_distem
    puts "\n\n**** Running #{this_method} ****"
    assert(@@coordinator != nil)
    assert(@@pnodes != nil)
  end

  def test_01_platform_api
    install_distem
    puts "\n\n**** Running #{this_method} ****"
    Net::SSH.start(@@coordinator, USER) { |session|
      launch_vnodes(session, {'pf_kind' => '2nodes', 'pnodes' => @@pnodes})
    }
  end

  def test_02_platform_cli
    install_distem
    puts "\n\n**** Running #{this_method} ****"
    Net::SSH.start(@@coordinator, USER) { |session|
      launch_vnodes(session, {'pf_kind' => '2nodes', 'pnodes' => @@pnodes, 'cli' => true})
    }
  end

  def test_03_latency_input
    install_distem
    puts "\n\n**** Running #{this_method} ****"
    Net::SSH.start(@@coordinator, USER) { |session|
      launch_vnodes(session, {'pf_kind' => '2nodes', 'pnodes' => @@pnodes})
      puts res = session.exec!("ruby #{File.join(ROOT,'exps/exp-latency.rb')} #{@@ref['latency']['error']} input 3")
      check_result(res)
    }
  end

  def test_04_latency_output
    install_distem
    puts "\n\n**** Running #{this_method} ****"
    Net::SSH.start(@@coordinator, USER) { |session|
      launch_vnodes(session, {'pf_kind' => '2nodes', 'pnodes' => @@pnodes})
      puts res = session.exec!("ruby #{File.join(ROOT,'exps/exp-latency.rb')} #{@@ref['latency']['error']} output 3")
      check_result(res)
    }
  end

  def test_05_bandwidth_input
    install_distem
    puts "\n\n**** Running #{this_method} ****"
    Net::SSH.start(@@coordinator, USER) { |session|
      launch_vnodes(session, {'pf_kind' => '2nodes', 'pnodes' => @@pnodes})
      puts res = session.exec!("ruby #{File.join(ROOT,'exps/exp-bandwidth.rb')} #{@@ref['bandwidth']['error']} input 3")
      check_result(res)
    }
  end

  def test_06_bandwidth_output
    install_distem
    puts "\n\n**** Running #{this_method} ****"
    Net::SSH.start(@@coordinator, USER) { |session|
      launch_vnodes(session, {'pf_kind' => '2nodes', 'pnodes' => @@pnodes})
      puts res = session.exec!("ruby #{File.join(ROOT,'exps/exp-bandwidth.rb')} #{@@ref['bandwidth']['error']} output 3")
      check_result(res)
    }
  end

  def test_07_hpcc_gov
    install_distem
    puts "\n\n**** Running #{this_method} ****"
    Net::SSH.start(@@coordinator, USER) { |session|
     launch_vnodes(session, {'pf_kind' => '1node_cpu'})
      [1,4].each { |nb_cpu|
        cpu = "#{nb_cpu}cpu"
        (0..(@@ref['hpcc']['freqs'].length - 1)).each { |i|
          check_result(session.exec!("ruby #{File.join(ROOT,'exps/exp-hpcc.rb')} #{nb_cpu} gov #{@@ref['hpcc']['freqs'][i]} #{@@ref['hpcc']['error']} #{@@ref['hpcc']['results'][cpu]['dgemm'][i]} #{@@ref['hpcc']['results'][cpu]['fft'][i]} #{@@ref['hpcc']['results'][cpu]['hpl'][i]}"))
        }
      }
    }
  end

  def test_08_hpcc_hogs
    install_distem
    puts "\n\n**** Running #{this_method} ****"
    Net::SSH.start(@@coordinator, USER) { |session|
      launch_vnodes(session, {'pf_kind' => '1node_cpu'})
      [1,4].each { |nb_cpu|
        cpu = "#{nb_cpu}cpu"
        (0..(@@ref['hpcc']['freqs'].length - 1)).each { |i|
          check_result(session.exec!("ruby #{File.join(ROOT,'exps/exp-hpcc.rb')} #{nb_cpu} HOGS #{@@ref['hpcc']['freqs'][i]} #{@@ref['hpcc']['error']} #{@@ref['hpcc']['results'][cpu]['dgemm'][i]} #{@@ref['hpcc']['results'][cpu]['fft'][i]} #{@@ref['hpcc']['results'][cpu]['hpl'][i]}"))
        }
      }
    }
  end

  def test_09_vectorized_init_and_connectivity
    install_distem
    puts "\n\n**** Running #{this_method} ****"
    Net::SSH.start(@@coordinator, USER) { |session|
      launch_vnodes(session, {'pf_kind' => '50nodes'})
      @@pnodes.uniq.each { |pnode|
        session.exec!("scp -o StrictHostKeyChecking=no /tmp/ip #{pnode}:/tmp") if (pnode != @@coordinator)
      }
    }
    @@pnodes.uniq.each { |pnode|
      Net::SSH.start(pnode, USER) { |session|
        check_result(session.exec!("ruby #{File.join(ROOT,'exps/exp-check-connectivity.rb')}"))
      }
    }
  end

  def test_10_set_peers_latency
    install_distem
    puts "\n\n**** Running #{this_method} ****"
    Net::SSH.start(@@coordinator, USER) { |session|
      launch_vnodes(session, {'pf_kind' => '50nodes'})
      check_result(session.exec!("ruby #{File.join(ROOT,'exps/exp-matrix-latencies.rb')}"))
    }
  end

  def test_11_set_arptables
    install_distem
    puts "\n\n**** Running #{this_method} ****"
    Net::SSH.start(@@coordinator, USER) { |session|
      launch_vnodes(session, {'pf_kind' => '50nodes'})
      check_result(session.exec!("ruby #{File.join(ROOT,'exps/exp-check-arp-tables.rb')}"))
    }
  end

  def test_12_wait_vnodes
    install_distem
    puts "\n\n**** Running #{this_method} ****"
    Net::SSH.start(@@coordinator, USER) { |session|
      launch_vnodes(session, {'pf_kind' => '200nodes', 'pnodes' => @@pnodes})
    }
  end

  def test_13_cpu_update
    install_distem
    puts "\n\n**** Running #{this_method} ****"
    Net::SSH.start(@@coordinator, USER) { |session|
      launch_vnodes(session, {'pf_kind' => '1node_cpu'})
      max_freq = @@ref['hpcc']['freqs'].last
      [1,2,4].each { |nb_cpu|
        ['HOGS','GOV'].each { |policy|
          check_result(session.exec!("ruby #{File.join(ROOT,'exps/exp-cpu-update.rb')} #{nb_cpu} #{policy} #{max_freq}"))
        }
      }
    }
  end

  def test_14_events
    install_distem
    puts "\n\n**** Running #{this_method} ****"
    Net::SSH.start(@@coordinator, USER) { |session|
      launch_vnodes(session, {'pf_kind' => '2nodes', 'pnodes' => @@pnodes})
      check_result(session.exec!("ruby #{File.join(ROOT,'exps/exp-events.rb')}"))
    }
  end

  def test_15_alevin
    temp_alevin = Tempfile.new("alevin.jar")
    puts "\n\n Downloading Alevin ***"
    `wget #{@@ref['alevin']['source']} -O #{temp_alevin.path} -q`
    install_distem("--alevin #{temp_alevin.path} -p default-jdk,graphviz")
    puts "\n\n**** Running #{this_method} ****"
    Net::SSH.start(@@coordinator, USER) { |session|
      launch_vnodes(session, {'pf_kind' => '1node_def'})
      check_result(session.exec!("ruby #{File.join(ROOT,'exps/exp-alevin.rb')}"))
    }
  end


end
