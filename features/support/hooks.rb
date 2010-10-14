require 'socket'

Before do
  @hudson_cleanup = []

  require "fileutils"

  FileUtils.cp(
    File.join(File.join(File.dirname(__FILE__), "..", "fixtures"), "no-authentication.config.xml"),
    File.join("/tmp/test_hudson", "config.xml")
  )

  port = @hudson_port || 3010

  Net::HTTP.start("localhost", port) do |http|
    req = Net::HTTP::Post.new("/reload/api/json")
    req.basic_auth "admin", "password"
    p http.request(req)
  end

  Net::HTTP.start("localhost", port) do |http|
    sleep 1 while http.get("/").body =~ /Please wait while Hudson is getting ready to work/
  end
end

After do
  for port in @hudson_cleanup do
    begin
      TCPSocket.open("localhost", port) do |sock|
        sock.write("0")
      end
    rescue
    end
  end
end