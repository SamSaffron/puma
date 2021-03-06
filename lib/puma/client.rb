module Puma
  class Client
    include Puma::Const

    def initialize(io, env)
      @io = io
      @to_io = io.to_io
      @proto_env = env
      @env = env.dup

      @parser = HttpParser.new
      @parsed_bytes = 0
      @read_header = true
      @ready = false

      @body = nil
      @buffer = nil

      @timeout_at = nil
    end

    attr_reader :env, :to_io, :body, :io, :timeout_at, :ready

    def set_timeout(val)
      @timeout_at = Time.now + val
    end

    def reset
      @parser.reset
      @read_header = true
      @env = @proto_env.dup
      @body = nil
      @parsed_bytes = 0
      @ready = false

      if @buffer
        @parsed_bytes = @parser.execute(@env, @buffer, @parsed_bytes)

        if @parser.finished?
          return setup_body
        elsif @parsed_bytes >= MAX_HEADER
          raise HttpParserError,
            "HEADER is longer than allowed, aborting client early."
        end

        return false
      end
    end

    def close
      begin
        @io.close
      rescue IOError
      end
    end

    # The object used for a request with no body. All requests with
    # no body share this one object since it has no state.
    EmptyBody = NullIO.new

    def setup_body
      body = @parser.body
      cl = @env[CONTENT_LENGTH]

      unless cl
        @buffer = body.empty? ? nil : body
        @body = EmptyBody
        @ready = true
        return true
      end

      remain = cl.to_i - body.bytesize

      if remain <= 0
        @body = StringIO.new(body)
        @buffer = nil
        @ready = true
        return true
      end

      if remain > MAX_BODY
        @body = Tempfile.new(Const::PUMA_TMP_BASE)
        @body.binmode
      else
        # The body[0,0] trick is to get an empty string in the same
        # encoding as body.
        @body = StringIO.new body[0,0]
      end

      @body.write body

      @body_remain = remain

      @read_header = false

      return false
    end

    def try_to_finish
      return read_body unless @read_header

      data = @io.readpartial(CHUNK_SIZE)

      if @buffer
        @buffer << data
      else
        @buffer = data
      end

      @parsed_bytes = @parser.execute(@env, @buffer, @parsed_bytes)

      if @parser.finished?
        return setup_body
      elsif @parsed_bytes >= MAX_HEADER
        raise HttpParserError,
          "HEADER is longer than allowed, aborting client early."
      end
      
      false
    end

    def eagerly_finish
      return true if @ready
      return false unless IO.select([@to_io], nil, nil, 0)
      try_to_finish
    end

    def read_body
      # Read an odd sized chunk so we can read even sized ones
      # after this
      remain = @body_remain

      if remain > CHUNK_SIZE
        want = CHUNK_SIZE
      else
        want = remain
      end

      chunk = @io.readpartial(want)

      # No chunk means a closed socket
      unless chunk
        @body.close
        @buffer = nil
        @ready = true
        raise EOFError
      end

      remain -= @body.write(chunk)

      if remain <= 0
        @body.rewind
        @buffer = nil
        @ready = true
        return true
      end

      @body_remain = remain

      false
    end
  end
end
