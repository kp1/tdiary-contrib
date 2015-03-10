#
# profile.rb: profile plugin for tDiary
#
# usage:
#   profile(id[, service = :twitter])
#   - id: user ID for profile service
#   - service: profile service (default is :twitter)
#     Choose from :github, :twitter, :friendfeed, :gravatar
#
# Copyright (C) 2009 by MATSUOKA Kohei < http://www.machu.jp/ >
# Distributed under the GPL.
#
require 'timeout'
require 'rexml/document'
require 'open-uri'
require 'digest/md5'
require 'pstore'

module ::Profile
  module Service
    # base class for profile services
    class Base
      # default attributes
      attr_reader :id
      attr_reader :image
      attr_reader :name
      attr_reader :mail
      attr_reader :description
      attr_reader :link

      # class instance variables
      class << self
        attr_reader :properties
        attr_reader :endpoint_proc
      end

      # set property and xpath pair for parse XML document
      def self.property(property, path)
        @properties ||= {}
        @properties[property] = path
      end

      # set endpoint proc (this proc is called by initialize method with id)
      def self.endpoint(&block)
        @endpoint_proc = block
      end

      def initialize(id, options = {})
        @id = id
        @options = options

        if self.class.endpoint_proc
          endpoint = self.class.endpoint_proc.call(id)
          doc = fetch(endpoint)
          parse(doc)
        end
      end

      # get a XML document from endpoint and create REXML::Document instance
      def fetch(endpoint)
        timeout(5) do
          open(endpoint) do |f|
            doc = REXML::Document.new(f)
          end
        end
      end

      # parse XML document with properties
      def parse(doc)
        self.class.properties.each do |property, path|
          if doc.elements[path]
            value = doc.elements[path].text
            instance_variable_set("@#{property}", value)
          end
        end
      end
    end

    # github.com
    class GitHub < Base
      property :name, 'name'
      property :mail, 'email'
      endpoint {|id| "https://api.github.com/users/#{id}" }

      def image
        # "http://www.gravatar.com/avatar/#{Digest::MD5.hexdigest(@mail)}.jpg"
        Gravatar.new(@mail, @options).image
      end

      def link
        "http://github.com/#{@id}"
      end

      def fetch(endpoint)
        require 'json'
        timeout(5) do
          doc = open(endpoint) {|f| JSON.parse(f.read) }
        end
      end

      def parse(doc)
        self.class.properties.each do |property, key|
          instance_variable_set("@#{property}", doc[key]) if doc[key]
        end
      end
    end

    # twitter.com
    class Twitter < Base
      property :name, '//user/name'
      property :image, '//user/profile_image_url'
      property :description, '//user/description'
      endpoint {|id| "http://twitter.com/users/show/#{id}.xml" }

      def link
        "http://twitter.com/#{@id}"
      end
    end

    # friendfeed.com
    class FriendFeed < Base
      property :name, '//feed/name'
      property :description, '//feed/description'
      endpoint {|id| "http://friendfeed-api.com/v2/feed/#{id}?format=xml&num=0" }

      def image
        "http://friendfeed-api.com/v2/picture/#{id}"
      end

      def link
        "http://friendfeed.com/#{@id}"
      end
    end

    # iddy.jp, for backward compatibility
    class Iddy < Base
      # dummy class
    end

    # gravatar.com
    class Gravatar < Base
      property :name, 'diaplayName'
      property :mail, 'email'
      endpoint {|id|
        hash = Digest::MD5.hexdigest(id.downcase)
        "https://www.gravatar.com/#{hash}.json"
      }

      def image
        size = @options[:size] ? "?s=#{@options[:size]}" : ""
        "#{@image_base}#{size}"
		end

      def fetch(endpoint)
        require 'json'
        timeout(5) do
          doc = open(endpoint) {|f| JSON.parse(f.read) }
        end
      end

      def parse(doc)
        instance_variable_set("@name", doc['entry'][0]['displayName'])
        instance_variable_set("@mail", @id)
        instance_variable_set("@image_base", doc['entry'][0]['thumbnailUrl'])
      end
    end

    class Hatena < Base
      def image
        prefix = id[0..1]
        "http://www.hatena.ne.jp/users/#{prefix}/#{id}/profile.gif"
      end

      def link
        "http://www.hatena.ne.jp/#{id}/"
      end
    end
  end
end

PROFILE_VERSION = '20090909'

def profile(id, service = :twitter, options = {})
  html = ''

  service_class = {
    :twitter => Profile::Service::Twitter,
    :github => Profile::Service::GitHub,
    :friendfeed => Profile::Service::FriendFeed,
    :gravatar => Profile::Service::Gravatar,
    :hatena => Profile::Service::Hatena,
  }[service.to_s.downcase.to_sym] || Profile::Service::Twitter

  # TODO: create cache manager class

  # cache = "#{@cache_path}/profile.yaml"
  cache = "#{@cache_path}/profile.pstore"
  profile = nil
  # db = YAML::Store.new(cache)
  db = PStore.new(cache)
  db.transaction do
    key = service_class.name
    db[key] ||= {} # initialize db
    updated = db[key][:updated]
    if updated && (Time::now < updated + 60 * 60) && db[key][:version] == PROFILE_VERSION
      # use cache
      profile = db[key][:profile]
    else
      # get latest date and update cache
      begin
        profile = service_class.new(id, options)
      rescue Timeout::Error, StandardError
        return html << %Q{ <div class="profile">no profile</div> }
      end
      db[key][:updated] = Time::now
      db[key][:profile] = profile
      db[key][:version] = PROFILE_VERSION
    end
  end

  html << %Q{ <div class="profile"><a href="#{CGI.escapeHTML profile.link}"> }
  html << %Q{ <span class="profile-image"><img src="#{CGI.escapeHTML profile.image}" alt="profile image"></span> } if profile.image
  html << %Q{ <span class="profile-name">#{CGI.escapeHTML profile.name}</span> } if profile.name
  html << %Q{ <span class="profile-mail">#{CGI.escapeHTML profile.mail}</span> } if profile.mail
  html << %Q{ <span class="profile-description">#{CGI.escapeHTML profile.description}</span> } if profile.description
  html << %Q{ </a></div> }
end
