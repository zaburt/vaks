require "net/http"
require "uri"
require "json"

module Vaks
  # Fires a JSON webhook POST on job success/failure -- a lightweight alternative
  # (or complement) to desktop notifications, usable with Slack incoming webhooks,
  # ntfy.sh, or any endpoint that accepts a JSON body.
  module Webhook
    # event: "success" or "failure"
    # payload: hash of job details (path, watch, duration, size_before, size_after, error)
    def self.notify(url, event, payload, logger: nil)
      return unless url

      uri  = URI.parse(url)
      body = JSON.generate(payload.merge(event: event, text: default_text(event, payload)))

      Thread.new do
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = uri.scheme == "https"
        http.open_timeout = 5
        http.read_timeout = 5
        req = Net::HTTP::Post.new(uri.request_uri.empty? ? "/" : uri.request_uri)
        req["Content-Type"] = "application/json"
        req.body = body
        http.request(req)
      rescue => e
        logger&.warn "Webhook delivery failed: #{e.message}"
      end
    end

    def self.default_text(event, payload)
      name = payload[:path] ? File.basename(payload[:path]) : "job"
      event == "success" ? "OK vaks: #{name} finished" : "FAIL vaks: #{name} failed"
    end
  end
end
