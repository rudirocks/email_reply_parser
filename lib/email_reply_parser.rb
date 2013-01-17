require 'strscan'

# EmailReplyParser is a small library to parse plain text email content.  The
# goal is to identify which fragments are quoted, part of a signature, or
# original body content.  We want to support both top and bottom posters, so
# no simple "REPLY ABOVE HERE" content is used.
#
# Beyond RFC 5322 (which is handled by the [Ruby mail gem][mail]), there aren't
# any real standards for how emails are created.  This attempts to parse out
# common conventions for things like replies:
#
#     this is some text
#
#     On <date>, <author> wrote:
#     > blah blah
#     > blah blah
#
# ... and signatures:
#
#     this is some text
#
#     --
#     Bob
#     http://homepage.com/~bob
#
# Each of these are parsed into Fragment objects.
#
# EmailReplyParser also attempts to figure out which of these blocks should
# be hidden from users.
#
# [mail]: https://github.com/mikel/mail
class EmailReplyParser
  VERSION = "0.5.1"

  # Public: Splits an email body into a list of Fragments.
  #
  # text - A String email body.
  #
  # Returns an Email instance.
  def self.read(text)
    Email.new.read(text)
  end

  # Public: Get the text of the visible portions of the given email body.
  #
  # text - A String email body.
  #
  # Returns a String.
  def self.parse_reply(text)
    self.read(text).visible_text
  end

  ### Emails

  # An Email instance represents a parsed body String.
  class Email
    # Emails have an Array of Fragments.
    attr_reader :fragments

    def initialize
      @fragments = []
    end

    # Public: Gets the combined text of the visible fragments of the email body.
    #
    # Returns a String.
    def visible_text
      fragments.select{|f| !f.hidden?}.map{|f| f.to_s}.join("\n").rstrip
    end

    # Splits the given text into a list of Fragments.  This is roughly done by
    # reversing the text and parsing from the bottom to the top.  This way we
    # can check for 'On <date>, <author> wrote:' lines above quoted blocks.
    #
    # text - A String email body.
    #
    # Returns this same Email instance.
    def read(text)
      # in 1.9 we want to operate on the raw bytes
      text = text.dup.force_encoding('binary') if text.respond_to?(:force_encoding)

      # Check for multi-line reply headers. Some clients break up
      # the "On DATE, NAME <EMAIL> wrote:" line into multiple lines.
      oneline_reply_headers(text)

      # The text is reversed initially due to the way we check for hidden
      # fragments.
      text = text.reverse

      # This determines if any 'visible' Fragment has been found.  Once any
      # visible Fragment is found, stop looking for hidden ones.
      @found_visible = false

      # This instance variable points to the current Fragment.  If the matched
      # line fits, it should be added to this Fragment.  Otherwise, finish it
      # and start a new Fragment.
      @fragment = nil

      # Use the StringScanner to pull out each line of the email content.
      @scanner = StringScanner.new(text)
      while line = @scanner.scan_until(/\n/n)
        scan_line(line)
      end

      # Be sure to parse the last line of the email.
      if (last_line = @scanner.rest.to_s).size > 0
        scan_line(last_line)
      end

      # Finish up the final fragment.  Finishing a fragment will detect any
      # attributes (hidden, signature, reply), and join each line into a
      # string.
      finish_fragment

      @scanner = @fragment = nil

      # Now that parsing is done, reverse the order.
      @fragments.reverse!
      self
    end

  private
    COMMON_REPLY_HEADER_REGEXES = [
      /^(On(.+)wrote:)$/nm,
      /^(Date:.*From:.*To:.*Subject:.*?)\n\n/nm,
      /( *\*?From:.*Sent:.*To:.*Subject:.*?)\n\n/nm
    ]
    COMMON_REPLY_HEADER_REGEXES_REVERSED = [
      /^:etorw.*nO$/n,
      /^.*:tcejbuS.*:oT.*:morF.*:etaD$/n,
      /^.*:tcejbuS.*:oT.*:tneS.*:morF\*?$/n
    ]
    EMPTY = "".freeze

    # Line optionally starts with spaces, contains two or more hyphens or underscores, and ends with optional whitespace. Example: '---' or '___' or '---   '
    MULTI_LINE_SIGNATURE_REGEX = /^\s*[-_]{2,}\s*$/

    # Word character followed by hyphen, ending the line with optional spaces. Example: '-Sandro'
    ONE_LINE_SIGNATURE_REGEX = /(\w-)\s*$/

    # No block-quotes (> or <), followed by up to three words, follwed by "Sent from my". Example: "Sent from my iPhone 3G"
    SENT_FROM_REGEX = /(^(>.*<\s*)*(\w+\s*){1,3} #{"Sent from my".reverse}$)/

    SIGNATURE_REGEX = Regexp.new(Regexp.union(MULTI_LINE_SIGNATURE_REGEX, ONE_LINE_SIGNATURE_REGEX, SENT_FROM_REGEX).source, Regexp::NOENCODING)


    # Detects if a given line is a common reply header.
    #
    # line - A String line of text from the email.
    #
    # Returns true if the line is a valid header, or false.
    def line_is_reply_header?(line)
      COMMON_REPLY_HEADER_REGEXES_REVERSED.each do |regex|
        return true if line =~ regex
      end
      false
    end

    # Tests the full text of the email to see if it contains a common reply
    # header. If so, removes any newlines and leading whitespace from the reply
    # header.
    #
    # text - A String email body.
    #
    # Returns nothing.
    def oneline_reply_headers(text)
      COMMON_REPLY_HEADER_REGEXES.each do |regex|
        if text =~ regex
          text.gsub!($1, $1.gsub("\n", " ").lstrip) and break
        end
      end
    end

    # Detects if a given line starts with a common signature indicator.
    #
    # line - A String line of text from the email.
    #
    # Returns true if the line starts with a common signature indicator.
    def line_is_signature?(line)
      line =~ SIGNATURE_REGEX
    end

    ### Line-by-Line Parsing

    # Scans the given line of text and figures out which fragment it belongs
    # to.
    #
    # line - A String line of text from the email.
    #
    # Returns nothing.
    def scan_line(line)
      line.chomp!("\n")
      line.lstrip! unless line =~ SIGNATURE_REGEX

      # We're looking for leading `>`'s to see if this line is part of a
      # quoted Fragment.
      is_quoted = !!(line =~ /(>+)$/n)

      # Mark the current Fragment as a signature if the current line is empty
      # and the Fragment starts with a common signature indicator.
      if @fragment && line == EMPTY && line_is_signature?(@fragment.lines.last)
        @fragment.signature = true
        finish_fragment
      end

      # Mark the current Fragment as a reply header if the current line is
      # empty and the Fragment starts with a common reply header.
      if @fragment && line == EMPTY && line_is_reply_header?(@fragment.lines.last)
        @fragment.reply_header = true
        finish_fragment
      end

      # If the line matches the current fragment, add it.  Note that a common
      # reply header also counts as part of the quoted Fragment, even though
      # it doesn't start with `>`.
      if @fragment &&
          ((@fragment.quoted? == is_quoted) ||
           (@fragment.quoted? && (line_is_reply_header?(line) || line == EMPTY)))
        @fragment.lines << line

      # Otherwise, finish the fragment and start a new one.
      else
        finish_fragment
        @fragment = Fragment.new(is_quoted, line)
      end
    end

    # Builds the fragment string and reverses it, after all lines have been
    # added.  It also checks to see if this Fragment is hidden.  The hidden
    # Fragment check reads from the bottom to the top.
    #
    # Any quoted Fragments or signature Fragments are marked hidden if they
    # are below any visible Fragments.  Visible Fragments are expected to
    # contain original content by the author.  If they are below a quoted
    # Fragment, then the Fragment should be visible to give context to the
    # reply.
    #
    #     some original text (visible)
    #
    #     > do you have any two's? (quoted, visible)
    #
    #     Go fish! (visible)
    #
    #     > --
    #     > Player 1 (quoted, hidden)
    #
    #     --
    #     Player 2 (signature, hidden)
    #
    def finish_fragment
      if @fragment
        @fragment.finish
        if !@found_visible
          if @fragment.quoted? || @fragment.signature? ||
              @fragment.reply_header? || @fragment.to_s.strip == EMPTY
            @fragment.hidden = true
          else
            @found_visible = true
          end
        end
        @fragments << @fragment
      end
      @fragment = nil
    end
  end

  ### Fragments

  # Represents a group of paragraphs in the email sharing common attributes.
  # Paragraphs should get their own fragment if they are a quoted area or a
  # signature.
  class Fragment < Struct.new(:quoted, :signature, :reply_header, :hidden)
    # This is an Array of String lines of content.  Since the content is
    # reversed, this array is backwards, and contains reversed strings.
    attr_reader :lines,

    # This is reserved for the joined String that is build when this Fragment
    # is finished.
      :content

    def initialize(quoted, first_line)
      self.signature = self.reply_header = self.hidden = false
      self.quoted = quoted
      @lines      = [first_line]
      @content    = nil
      @lines.compact!
    end

    alias quoted?    quoted
    alias signature? signature
    alias reply_header? reply_header
    alias hidden?    hidden

    # Builds the string content by joining the lines and reversing them.
    #
    # Returns nothing.
    def finish
      @content = @lines.join("\n")
      @lines = nil
      @content.reverse!
    end

    def to_s
      @content
    end

    def inspect
      to_s.inspect
    end
  end
end

