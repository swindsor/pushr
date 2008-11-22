require 'rubygems'
require 'sinatra'
require 'yaml'
require 'logger'

# = Pushr
# Deploy Rails applications by Github Post-Receive URLs launching Capistrano's <tt>cap deploy</tt>
# An experiment.

CONFIG = YAML.load_file( File.join(File.dirname(__FILE__), 'config.yml') ) unless defined? CONFIG

# == Pushr module
# Wrap classes into a separate namespace.
module Pushr
  
  unless defined? LOGGER
    LOGGER       = Logger.new(File.join(File.dirname(__FILE__), 'deploy.log'), 'weekly')
    LOGGER.level = Logger::INFO
  end

  # == Pushr class
  # Just wrapping the logic somehow, at the moment.
  class Pushr
    
    attr_accessor :applications

    def initialize(applications)
      @applications = applications.collect { |app| Application.new(app) }
    end

    def deploy!
      success = true
      output = applications.inject([]) do |output, app|
        output << "#{app.name}&#x000A;========================================"
        app_success, app_output = app.deploy!
        output << app_output
        success = false unless app_success 
        output
      end
      
      { :success => success, :output  => output.join("&#x000A;") }
    end

  end # end Pushr class

  class Application
    attr_reader :path, :name, :repository, :config
    
    Struct.new('Repository', :revision, :message, :author, :when, :datetime) unless defined? Struct::Repository

    def initialize(app)
      path = app['path']
      log.fatal('Pushr::Application.new') { "Path not valid: #{path}" } and raise ArgumentError, "File not found: #{path}" unless File.exists?(path)
      @config = app
      @path = path
      @name = app['name'] || "You really should set this to something"
      @repository  = repository_info
    end
    
    def log
      LOGGER
    end
    
    def repo
      config['repository']
    end
    
    def in_path(action)
      `cd #{path}/shared/cached-copy && #{action}`
    end
    
    def in_repo(action)
      `cd #{repo} && #{action}`
    end

    def git_version
      in_repo "git rev-list HEAD --max-count=1"
    end

    def live_version 
      in_path "git rev-list HEAD --max-count=1"
    end
    
    def deploy!
      # TODO : Refactor logging/notifying into Observers, obviously!
      config['cap']['action'] or raise "cap.action is a required setting"
    
      log.info(name) { "Downloading updates..." }

      git_output   = in_repo "git pull"
      # WARNING: it's still possible to get a race condition if several
      # patches are checked in quickly-- deploy.rb might get run from
      # version N, and the deployment might deploy newer code version N+1
      # Usually this won't matter, since deploy.rb probably doesn't change
      # But if you think that this might cause problems, in deploy.rb
      # "set :repository" to pushr's local repository, so only pushr is connecting
      # to the outside world.

      log.info(name) { "Checking versions..." }

    
      if(git_version == live_version)
        #TODO: allow force option to re-deploy same version
        log.fatal(name){ 'No updates found' }
        return "No upgrade required."
      end
      log.info("let's update from #{live_version} to #{git_version}")

      historical = in_repo('git rev-list HEAD').split.grep live_version
      if not historical
        log.fatal(name){ 'Your deployed app is not an ancestor of your repository HEAD!' }
      end
    
      log.info(name) { "Deployment starting..." }

      cap_output = in_repo "cap #{config['cap']['action']} 2>&1"
      success    = (cap_output.to_s =~ /failed/).nil? && ! cap_output.empty?
      # ---> Log
      if success
        log.info('[SUCCESS]')   { "Successfuly deployed application with revision #{repository.revision} (#{repository.message}). Capistrano output:" }
        log.info('Capistrano') { cap_output.to_s }
      else
        log.warn('[FAILURE]')   { "Error when deploying application! Check Capistrano output below:" }
        log.warn('Capistrano') { cap_output.to_s }
      end
      # ---> Twitter
      if CONFIG['twitter'] && !CONFIG['twitter']['username'].nil? && !CONFIG['twitter']['password'].nil?
        twitter_message = (success) ?
          "Deployed #{name} with revision #{repository.revision} — #{repository.message.slice(0, 100)}" :
          "FAIL! Deploying #{name} failed. Check log for details."
        %x[curl --silent --data status='#{twitter_message}' http://#{CONFIG['twitter']['username']}:#{CONFIG['twitter']['password']}@twitter.com/statuses/update.json]
      end
      
      return [success, cap_output.to_s]
    end
    
    private
    
    def repository_info
      sep = ' ;;;;; '
      info = in_path " git log --pretty='format:%h#{sep}%s#{sep}%an#{sep}%ar#{sep}%ci' -n 1 "
      Struct::Repository.new( *info.split(/#{sep}/) )
    end
  end # end Application class

end # end Pushr module


# Log into file in production
configure :production do
  sinatra_log = File.new(File.join( File.dirname(__FILE__), 'sinatra.log'), "w")
  STDOUT.reopen(sinatra_log)
  STDERR.reopen(sinatra_log)
end

# Authorize all requests with the token set in <tt>config.yml</tt>
before do
  throw :halt, [404, "Not configured\n"] and return if not CONFIG['token'] or CONFIG['token'].nil?
  throw :halt, [500, "You did wrong.\n"] and return unless params[:token] && params[:token] == CONFIG['token']
end

error do 
  request.env['sinatra.error'].to_s
end

# == Get info
get '/' do
  @pushr = Pushr::Pushr.new(CONFIG['applications'])

  haml :info
end

# == Deploy!
post '/' do
  @pushr = Pushr::Pushr.new(CONFIG['applications'])
  @info = @pushr.deploy!
  haml :deployed
end

get '/style.css' do
  content_type 'text/css', :charset => 'utf-8'
  sass :style
end

use_in_file_templates!

__END__

@@ layout
%html
  %head
    %title= "[pushr] #{CONFIG['name']}"
    %meta{ 'http-equiv' => 'Content-Type', :content => 'text/html;charset=utf-8' }
    %link{ :rel => 'stylesheet', :type => 'text/css', :href => "/style.css?token=#{CONFIG['token']}" }
  %body
    = yield

@@ info
%div.info
  - @pushr.applications.each do |app|
    %p
      Last deployed revision of
      %strong
        %em
          = app.name
      is
      %strong
        = app.repository.revision
      \:
      %strong
        %em
          = app.repository.message
      committed
      %strong
        = app.repository.when
      by
    = app.repository.author
  %p
    %form{ :action => "/", :method => 'post', :onsubmit => "this.submit.disabled='true'" }
      %input{ 'type' => 'hidden', 'name' => 'token', 'value' => CONFIG['token'] }
      %input{ 'type' => 'submit', 'value' => 'Deploy!', 'name' => 'submit', :id => 'submit' }


@@ deployed
- if @info[:success]
  %div.success
    %h2
      Application(s) deployed successfully.
    %form{ 'action' => "", :method => 'get' }
      %input{ 'type' => 'hidden', 'name' => 'token', 'value' => CONFIG['token'] }
      %p
        %input{ 'type' => 'submit', 'value' => 'Return to index' }
    %pre
      = @info[:output]
- else
  %div.failure
    %h2 There were errors when deploying the application!
    %pre
      = @info[:output]

@@ style
body
  :color #000
  :background #f8f8f8
  :font-size 90%
  :font-family Helvetica, Tahoma, sans-serif
  :line-height 1.5
  :padding 10%
  :text-align center
div
  :border 4px solid #ccc
  :padding 3em
div h2
  :margin-bottom 1em
a
  :color #000
div.success h2
  :color #128B45
div.failure h2
  :color #E21F3A
pre
  :color #444
  :font-size 95%
  :text-align left
  :word-wrap  break-word
  :white-space pre
  :white-space pre-wrap
  :white-space -moz-pre-wrap
  :white-space -o-pre-wrap
