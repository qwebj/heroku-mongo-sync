module Heroku::Command
  class Mongo < BaseWithApp
    def initialize(*args)
      opts = Trollop::options do
        opt :app, "Application name", :type => :string
        opt :except, "Except collections for sync", :short => 'e', :type => :strings
        opt :only, "Collection for sync", :short => 'o', :type => :strings
      end
      @except = opts[:except] || []
      @only = opts[:only] || []
      super

      require 'mongo'
    rescue LoadError
      error "Install the Mongo gem to use mongo commands:\nsudo gem install mongo"
    end

    def push
      display "THIS WILL REPLACE ALL DATA for #{app} ON #{heroku_mongo_uri.host} WITH #{local_mongo_uri.host}"
      display "Are you sure? (y/n) ", false
      some_info()
      return unless ask.downcase == 'y'
      transfer(local_mongo_uri, heroku_mongo_uri)
    end

    def pull
      display "Replacing the #{app} db at #{local_mongo_uri.host} with #{heroku_mongo_uri.host}"
      some_info()
      transfer(heroku_mongo_uri, local_mongo_uri)
    end

    protected
      def some_info
        display "Except collections: #{@except.join(', ')}" if @except.any?
        display "Sync only: #{@only.join(', ')}" if @only.any?
      end

      def transfer(from, to)
        raise "The destination and origin URL cannot be the same." if from == to
        raise "Only or Except not both" if @only.any? and @except.any?
        origin = make_connection(from)
        dest   = make_connection(to)

        origin.collections.each do |col|
          next if col.name =~ /^system\./ or @except.include?(col.name) or @only.any? and !@only.include?(col.name)

          dest.drop_collection(col.name)
          dest_col = dest.create_collection(col.name)

          col.find().each_with_index do |record, index|
            dest_col.insert record
            display_progress(col, index)
          end

          display "\n done"
        end

        display "Syncing indexes...", false
        dest_index_col = dest.collection('system.indexes')
        origin_index_col = origin.collection('system.indexes')
        origin_index_col.find().each do |index|
          if index['_id']
            index['ns'] = index['ns'].sub(origin_index_col.db.name, dest_index_col.db.name)
            dest_index_col.insert index
          end
        end
        display " done"
      end

      def heroku_mongo_uri
        config = Heroku::Auth.api.get_config_vars(app).body
        url    = config['MONGO_URL'] || config['MONGOHQ_URL'] || config['MONGOLAB_URI']
        error("Could not find the MONGO_URL for #{app}") unless url
        make_uri(url)
      end

      def local_mongo_uri
        url = ENV['MONGO_URL'] || "mongodb://localhost:27017/#{app}"
        make_uri(url)
      end

      def make_uri(url)
        urlsub = url.gsub('local.mongohq.com', 'mongohq.com')
        uri = URI.parse(urlsub)
        raise URI::InvalidURIError unless uri.host
        uri
      rescue URI::InvalidURIError
        error("Invalid mongo url: #{url}")
      end

      def make_connection(uri)
        connection = ::Mongo::Connection.new(uri.host, uri.port)
        db = connection.db(uri.path.gsub(/^\//, ''))
        db.authenticate(uri.user, uri.password) if uri.user
        db
      rescue ::Mongo::ConnectionFailure
        error("Could not connect to the mongo server at #{uri}")
      end

      def display_progress(col, index)
        count = col.size
        if (index + 1) % step(col) == 0
          display(
            "\r#{"Syncing #{col.name}: %d of %d (%.2f%%)... " %
            [(index+1), count, ((index+1).to_f/count * 100)]}",
            false
          )
        end
      end

      def step(col)
        step  = col.size / 100000 # 1/1000 of a percent
        step  = 1 if step == 0
      end

      Help.group 'Mongo' do |group|
        group.command 'mongo:push', 'push the local mongo database'
        group.command 'mongo:pull', 'pull from the production mongo database'
      end
  end
end
