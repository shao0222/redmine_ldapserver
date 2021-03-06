#!/usr/bin/env ruby
#coding: utf-8

require 'rubygems'
require 'optparse'
require 'yaml'
require 'active_record'
require 'ldap/server'
require 'thread'
require 'resolv-replace' # ruby threading DNS client
require 'digest/sha1'
require 'fileutils'

conf = {:daemonize => false,
        :debug => false,
        :env => 'production',
        :root => File.expand_path('../../../../', __FILE__),
        :basedn => "dc=example,dc=org",
        :pool_size => 2,
        :pw_cache => 10,
        :pid => "/tmp/#{File.basename(__FILE__)}.pid",
        :port => 1389
}

opt_parser = OptionParser.new do |opt|
  opt.on("-p", "--port=LISTENPORT", "which tcp-port you want server listen") do |port|
    conf[:port] = port.to_i
  end
  opt.on("-b", "--background", "run in background") do |background|
    conf[:daemonize] = true
  end
  opt.on("-s", "--basedn=BASEDN", "BASEDN") do |basedn|
    conf[:basedn] = basedn
  end
  opt.on("-l", "--pool=POOLSIZE", "Size of sql pool") do |pool|
    conf[:pool_size] = pool.to_i
  end
  opt.on("-c", "--cache=CACHESIZE", "Size of internal cache") do |cache|
    conf[:pw_cache] = cache.to_i
  end
  opt.on("-d", "--debug", "DEBUG") do |debug|
    conf[:debug] = true
  end

  opt.on("-w", "--pid=PIDFILE", "Path to pid file") do |pid|
    conf[:pid] = pid
  end

  opt.on("-e", "--env=ENV", "Rails.env") do |env|
    conf[:env] = env
  end

  opt.on("-r", "--root=ROOTDIR", "Rails.root") do |root|
    conf[:root] = root
  end

  opt.on("-f", "--foreground", "Run in foreground") do |op|
    conf[:daemonize] = false
  end


  opt.on_tail("-h", "--help", "Show this message") do
    puts opt
    exit
  end

end

opt_parser.parse!

exit if conf[:root].nil?

dbconf = YAML.load(File.read("#{conf[:root]}/config/database.yml"))

conf[:db] = dbconf[conf[:env]]
conf[:db]['pool'] = conf[:pool_size]


# To test:
#    ldapsearch -H ldap://127.0.0.1:1389/ -b "dc=example,dc=com" \
#       -D "uid=mylogin,dc=example,dc=com" -W "(uid=searchlogin)"


$debug = conf[:debug]

module RedmineLDAPSrv

  class LRUCache
    def initialize(size)
      @size = size
      @cache = [] # [[key,val],[key,val],...]
      @mutex = Mutex.new
    end

    def purge
      @mutex.synchronize do
        @cache = []
      end
    end

    def add(id, data)
      @mutex.synchronize do
        @cache.delete_if { |k, v| k == id }
        @cache.unshift [id, data]
        @cache.pop while @cache.size > @size
      end
    end

    def find(id)
      @mutex.synchronize do
        index = entry = nil
        @cache.each_with_index do |e, i|
          if e[0] == id
            entry = e
            index = i
            break
          end
        end
        return nil unless index
        @cache.delete_at(index)
        @cache.unshift entry
        return entry[1]
      end
    end
  end


  class SQLOperation < LDAP::Server::Operation
    def self.configure(conf)
      ActiveRecord::Base.establish_connection(conf[:db])
      @@cache = LRUCache.new(conf[:pw_cache])
      @@basedn = conf[:basedn]
      @@ldapdb = nil
    end

    def self.reload
      @@cache.purge
      @@ldapdb = nil
    end

    def initialize(connection, messageID)
      super(connection, messageID)
      @server.root_dse['subschemaSubentry'] = "cn=Subschema"
    end

    def load_ldapdb(dn)
      @@ldapdb = []
      oufilter = ""
      if dn =~/\Aou=([\w|-]+),#{@@basedn}\z/
        oufilter = "AND g.lastname = " + ActiveRecord::Base.connection.quote($1)
      end
      prev_user = nil
      sql = "SELECT
              g.lastname AS groupname,
              u.login AS member,
              e.address AS mail,
              u.firstname AS firstname,
              u.lastname AS lastname,
              u.LANGUAGE AS LANGUAGE
            FROM
              users AS g
            INNER JOIN groups_users AS gu ON g.id = gu.group_id
            RIGHT JOIN users u ON u.id = gu.user_id
            LEFT JOIN email_addresses e ON e.user_id = u.id
            WHERE
              u.STATUS = 1
            AND u.type = 'User'
            AND u.auth_source_id IS NULL
            #{oufilter}
            ORDER BY
              u.login
            "
      puts "SQL Query: #{sql}" if $debug
      rows = ActiveRecord::Base.connection.select_all(sql)
      rows.each do |row|
        if prev_user != row['member']
          @@ldapdb.unshift(["uid=#{row['member']},#{dn}", {
            'uid'       => [ row['member'] ],
            'groups'    => [ ],
            'mail'      => [ row['mail'] ],
            'language'  => [ row['language'] ],
            'firstname' => [ row['firstname'] ],
            'lastname'  => [ row['lastname'] ],
            'fullname'  => [ row['firstname'] + row['lastname'] ]
          }])
          prev_user = row['member']
        end
        @@ldapdb[0][1]['groups'].push(row['groupname']) unless row['groupname'].nil?
      end

      p @@ldapdb if $debug
    end

    def search(basedn, scope, deref, filter)
      puts "binddn: #{@connection.binddn}, basedn: #{basedn}, scope: #{scope}, deref: #{deref}, filter: #{filter}" if $debug
      # deny anonymous
      raise LDAP::ResultError::InvalidCredentials unless @connection.binddn
      load_ldapdb(basedn)
#      basedn.downcase!
      ok = false
      case scope
        when LDAP::Server::WholeSubtree
          puts "search subtree" if $debug
          @@ldapdb.each do |row|
            dn = row[0]
            av = row[1]
            next unless dn.index(basedn, -basedn.length) # under basedn?
            next unless LDAP::Server::Filter.run(filter, av) # attribute filter?
            puts "filter: #{filter.inspect}, av: #{av.inspect}" if $debug
            ok = true
            send_SearchResultEntry(dn, av)
          end
        else
          raise LDAP::ResultError::UnwillingToPerform, "OneLevel not implemented"
      end
      puts "nosuchobject" if $debug and !ok
      raise LDAP::ResultError::NoSuchObject unless ok
    end

    def simple_bind(version, dn, password)
      return if dn.nil? # accept anonymous
      puts "version: #{version}, dn: #{dn}, password: ********" if $debug
      raise LDAP::ResultError::UnwillingToPerform unless dn =~/\Auid=([\w|-]+),#{@@basedn}\z/ || dn =~/\Auid=([\w|-]+),ou=([\w|-]+),#{@@basedn}\z/
      login = $1
      data = @@cache.find(login)
      calculated_hash = Digest::SHA1.hexdigest(password)
      unless data
        user = ActiveRecord::Base.connection.quote(login)
        pwd = ActiveRecord::Base.connection.quote(calculated_hash)
        sql = "select salt,hashed_password from users where login=#{user} and sha1(concat(salt,#{pwd})) = hashed_password and status = 1 and auth_source_id is null"
        puts "SQL Query: #{sql}" if $debug
        rows = ActiveRecord::Base.connection.select_all(sql)
        if rows.count == 1
          rows.each do |row|
            data = row
            @@cache.add(login, data)
          end
        end
      end
      raise LDAP::ResultError::InvalidCredentials unless !data.nil? and data['salt'] != "" and data['hashed_password'] == Digest::SHA1.hexdigest("#{data['salt']}#{calculated_hash}")
    end
  end
end
##############################################################################
def with_lock_file(pid)
  return false unless obtain_lock(pid)
  begin
    yield
  ensure
    remove_lock(pid)
  end
end

def obtain_lock(pid)
  if File.exist?(pid)
    begin
      Process.getpgid(File.read(pid).to_i)
    rescue
      remove_lock(pid)
    end
  end
  File.open(pid, File::CREAT | File::EXCL | File::WRONLY) do |o|
    o.write(Process.pid)
  end
  return true
rescue
  return false
end

def remove_lock(pid)
  FileUtils.rm(pid, :force => true) if File.exists?(pid)
end

##############################################################################
Signal.trap("USR1") do
  puts "Reloading" if $debug
  RedmineLDAPSrv::SQLOperation.reload()
end

Signal.trap("TERM") do
  puts "Stoping." if $debug
  remove_lock(conf[:pid])
  Process.exit
end

Signal.trap("INT") do
  puts "Terminating." if $debug
  remove_lock(conf[:pid])
  Process.exit
end


Process.daemon if conf[:daemonize]


with_lock_file(conf[:pid]) do
  begin
    RedmineLDAPSrv::SQLOperation.configure(conf)
    s = LDAP::Server.new(
        :port => conf[:port],
        :nodelay => true,
        :listen => 10,
        :operation_class => RedmineLDAPSrv::SQLOperation
    )
    s.run_tcpserver
    s.join
  rescue Exception => e
    remove_lock(conf[:pid])
    puts "[LDAPSrv] Terminating application, raised unrecoverable error - #{e.message}!!!"
  end

end
