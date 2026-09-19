# frozen_string_literal: true

require "json"
require "shellwords"
require "time"

module Vdd
  module Commands
    module Logs
      module_function

      def call(issue_id:, state_dir:, exclude: nil)
        paths = Dir.glob(File.join(state_dir.to_s, "logs", issue_id.to_s, "*.log"))
                    .select { |path| File.file?(path) && !File.symlink?(path) }
                    .reject { |path| path == exclude }
        records = paths.map { |path| parse(path) }.sort_by { |record| [record[:started_at].to_s, record[:path]] }
        { status: "success", phase: "complete", logs: records, latest: records.last&.fetch(:path, nil) }
      end

      def render(payload)
        lines = ["index  command       status       duration  path",
                 "-----  ------------  -----------  --------  ----"]
        payload.fetch(:logs).each_with_index do |record, index|
          duration = record[:duration].nil? ? "-" : format("%.3fs", record[:duration])
          lines << format("%5d  %-12s  %-11s  %8s  %s", index + 1, record[:command], record[:status], duration,
                          record[:path])
        end
        lines.join("\n")
      end

      def follow(path, output: $stdout, poll_interval: 0.1, io_select: IO.method(:select))
        File.open(path, "r") do |file|
          loop do
            finished = false
            while (line = file.gets)
              output.write(line)
              finished ||= line.match?(/\] event=finish\b/) || line.include?(" finish status=")
            end
            break if finished

            io_select.call([file], nil, nil, poll_interval)
            sleep(poll_interval) if file.eof?
          end
        end
      rescue Errno::ENOENT, Errno::EACCES
        nil
      end

      def parse(path)
        started_at = nil
        command = "unknown"
        status = "running"
        duration = nil
        start_time = nil
        finish_time = nil
        events = []
        File.foreach(path) do |line|
          ts = line[/\A\[([^\]]+)\]/, 1]
          started_at ||= ts
          fields = structured_fields(line)
          if fields
            event = structured_event(fields)
            events << event
            details = event[:details]
            command = fields["command"] || details&.fetch("command", nil) || fields["action"].to_s.split(".").first
            if fields["event"] == "start"
              start_time = parse_time(ts)
            elsif fields["event"] == "finish"
              status = fields.fetch("status")
              finish_time = parse_time(ts)
            end
            duration = fields["duration"].to_f if fields["duration"]
          else
            parse_legacy_line(line, ts, state = {
              command: command,
              status: status,
              duration: duration,
              start_time: start_time,
              finish_time: finish_time
            })
            command = state[:command]
            status = state[:status]
            duration = state[:duration]
            start_time = state[:start_time]
            finish_time = state[:finish_time]
          end
        end
        if duration.nil? && start_time && finish_time
          duration = [(finish_time - start_time).to_f, 0.0].max
        end
        { command: command, status: status, duration: duration, path: path, started_at: started_at, events: events }
      rescue Errno::ENOENT, Errno::EACCES
        { command: "unknown", status: "unavailable", duration: nil, path: path, started_at: nil, events: [] }
      end
      private_class_method :parse

      def structured_fields(line)
        payload = line.sub(/\A\[[^\]]+\]\s+/, "")
        return unless payload.start_with?("event=")

        values = Shellwords.split(payload).each_with_object({}) do |field, parsed|
          key, value = field.split("=", 2)
          return unless key && value

          parsed[key] = value
        end
        raw_details = payload[/\bdetails=(\{.*\})\s*\z/, 1]
        values["details"] = raw_details if raw_details && valid_json?(raw_details)
        return unless %w[start progress success warning error finish].include?(values["event"])
        return unless %w[event action status message].all? { |key| values.key?(key) }
        values
      rescue ArgumentError
        nil
      end

      def valid_json?(value)
        JSON.parse(value)
        true
      rescue JSON::ParserError
        false
      end

      def structured_event(fields)
        event = {
          event: fields.fetch("event"),
          action: fields.fetch("action"),
          status: fields.fetch("status"),
          message: fields.fetch("message")
        }
        event[:duration] = fields["duration"].to_f if fields["duration"]
        details = parse_details(fields["details"])
        event[:details] = details if details
        event
      end

      def parse_details(value)
        return if value.to_s.empty?

        JSON.parse(value)
      rescue JSON::ParserError
        nil
      end

      def parse_legacy_line(line, timestamp, state)
        if line =~ /\A\[[^\]]+\]\s+start\b.*?\b(?:command|action)=([^\s]+)/
          command = Regexp.last_match(1).to_s.strip
          state[:command] = command unless command.empty?
          state[:start_time] = parse_time(timestamp)
        end
        if line =~ /\A\[[^\]]+\]\s+finish\s+status=([^\s]+(?:\s[^\n]+)?)$/
          state[:status] = Regexp.last_match(1).to_s.strip
          state[:finish_time] = parse_time(timestamp)
        end
        if line =~ /\A\[[^\]]+\]\s+duration=([0-9.]+)/
          state[:duration] = Regexp.last_match(1).to_f
        end
      end

      def parse_time(value)
        Time.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
