require 'etc'
require 'fileutils'
require 'yaml'
require 'rubygems'
require 'grit'
include Grit

####  Wanna add a job manually?  drop into irb in this directory
#
# app = "Project1"
# branch = "master"
#
# require 'branch_watcher'
# CiProject.init_projects
# builder = HudsonJobBuilder.new
# project = CiProject.all_projects.detect {|project| project.name == app}
# # Now add a job for that branch to that project
# builder.build_job_for(project, branch)
#
# Other notes
# project.job_name("master") returns e.g. Project1 master
# builder.current_hudson_jobs # see current jobs if you want
#
# All project builds are in ~/.hudson/server/jobs
# such that the master branch of Project1 is in
# ~/.hudson/server/jobs/Project1_master/workspace (in case you need to do anything in there, like update a bundle)
class CiProject

  attr_accessor :name, :directory, :ruby, :gemset, :repo_uri, :build_email

  PROJECT_DATA = YAML::load File.read(File.expand_path('ci_config.yml',File.dirname(__FILE__)))

  class << self
    attr_accessor :build_email
    def init_projects
      @build_email = PROJECT_DATA[:email]
      @projects = PROJECT_DATA[:repo_config].map do |name, dir, ruby, repo_uri|
        CiProject.new(name, dir, ruby, repo_uri)
      end
      @project_hash = {}
      @projects.each do |project|
        @project_hash[project.name] = project
      end
    end

    def all_projects
      @projects
    end

    def by_name(name)
      @project_hash[name]
    end

  end

  def initialize(name, directory, ruby, repo_uri)
    @name = name
    @directory = directory
    @ruby = ruby
    @repo_uri = repo_uri
    @build_email = self.class.build_email
  end

  def home_dir
    Etc.getpwuid.dir
  end
  def dir_name
    dir = "#{home_dir}/Sites/#{directory}"
    FileUtils.mkdir_p(dir)
    dir
  end

  def repo
    @repo ||= Repo.new(dir_name)
  end

  def with_rvm?
    false
  end

  def rvm_string
    "#{ruby}@#{directory}"
  end

  def set_rvmrc
    `rm .rvmrc*`
    `rvm --create --rvmrc "#{rvm_string}"`
  rescue StandardError => e
    puts "Failed to set rvmrc, error #{e.message}"
  end
  def delete_gemfile_lock?
    false
  end
  def delete_gemfile_lock
    puts "Deleting Gemfile.lock"
    `rm -rf Gemfile.lock`
  rescue Exception => e
    puts "Failed deleting Gemfile.lock. Did you delete it already? Error: #{e.message}"
  end

  def active_branches
    @active_branches ||= begin
      p dir_name
      Dir.chdir(dir_name) do
        `git remote prune origin`
        `git reset --hard HEAD`
        `git pull`
        #response =  `git reset --hard origin/$(git branch | grep '*' | cut -d' ' -f2) 2>&1` #rediret STDERR to STDOUT
        #puts response
        set_rvmrc if with_rvm?
        delete_gemfile_lock if delete_gemfile_lock?
      end
      result = []
      repo.remotes.each do |remote|
        next if remote.commit.id == "ref:"
        last_commit = remote.commit.committed_date
        days_ago = (Time.now - last_commit) / (60 * 60 * 24)
        p "#{remote.name.to_s} #{days_ago}"
        result << remote.name.to_s.split("/")[-1] if days_ago < 10
      end
      result
    end
  end

  def active?(branch)
    active_branches.include?(branch)
  end

  def job_name(branch)
    "#{name}_#{branch}"
  end

end

class HudsonJobBuilder

  def current_hudson_jobs
    @current_hudson_jobs ||= begin
      response = `hudson list --port 3001 --nocolor`
      result = response.split("\n").select { |l| l[0,1] == "*" }
      result.map { |s| s[2..-1] }
    end
  end

  def build_jobs_for(project)
    project.active_branches.each do |branch|
      build_job_for(project, branch)
    end
  end

  def remove_jobs
    current_hudson_jobs.each do |job_name|
      project_branch = job_name.split[-1]
      project_name = job_name.split[0 .. -2].join(" ")
      project = CiProject.by_name(project_name)
      next if project.nil?
      unless project.active?(project_branch)
        p "removing branch #{project_branch} of #{project_name}"
        result = `hudson remove "/Users/continuum/.hudson/server/jobs/#{job_name}"`
        p result
      end
    end
  end

  def build_job_for(project, branch)
    job_name = project.job_name(branch)
    if current_hudson_jobs.include?(job_name)
      p "#{job_name} already exists"
    else
      p "About to build a job for #{job_name}"
      gemset = project.with_rvm? ? "--gemset #{project.rvm_string}" : "--gemset #{project.ruby}@global"
      cmd = %Q(hudson create "#{project.dir_name}" --name "#{job_name}"  --port 3001 --scm #{project.repo_uri} --template rakeci --scm-branches #{branch} #{gemset} --email #{project.build_email})
      p cmd
      `#{cmd}`
    end
  end

end



if __FILE__ == $0
  CiProject.init_projects
  builder = HudsonJobBuilder.new
  builder.remove_jobs
  CiProject.all_projects.each do |project|
   builder.build_jobs_for(project)
  end
end
