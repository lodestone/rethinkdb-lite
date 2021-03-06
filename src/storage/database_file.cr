require "./arch_utils"
require "./pages"

module Storage
  class DatabaseFile
    def initialize(@file : File, @wal_file : File)
      @file.sync = true
      @file.rewind
      @wal_file.sync = true
      @wal_file.rewind

      @page_size = 1024u64
      @page_count = 1u32
      @real_page_count = 1u32
      @first_free_page = 0u32
      @wal = Deque(Hash(UInt32, UInt32)).new
      @wal_usage = Deque(UInt32).new
      @wal_usage << 0u32
      @next_wal = Hash(UInt32, UInt32).new
      @wal_count = 1u32
      @wal_skip = 0u32
      @pending_wal = Hash(UInt32, Bytes).new

      header = read_file_page(0u32).as_header.value

      @page_size = header.page_size.to_u64
      @file.seek(0, IO::Seek::End)
      @page_count = (@file.pos / @page_size).to_u32
      @real_page_count = @page_count
      @first_free_page = header.first_free_page

      @skip = 1u32
      @skip = read_wal_page(0u32).as_wal.value.skip_page_count
      @wal_file.seek(0, IO::Seek::End)
      @wal_count = (@wal_file.pos / @page_size).to_u32
      last_commit_pos = 0u32
      next_page_count = @page_count
      (@skip...@wal_count).each do |wpos|
        page = read_wal_page(wpos)
        if page.type == 'C'
          @wal << @next_wal
          @wal_usage << 0u32
          @next_wal = Hash(UInt32, UInt32).new
          last_commit_pos = wpos
          @page_count = next_page_count
        else
          next_page_count = {next_page_count, page.pos + 1}.max
          @next_wal[page.pos] = wpos
        end
      end
      @wal_count = last_commit_pos + 1
      @next_wal = Hash(UInt32, UInt32).new
    end

    def close
      flush!
      @file.close
      @wal_file.close
    end

    struct Writter
      def initialize(@db : DatabaseFile)
      end

      def reader
        Reader.new(@db, -1)
      end

      def alloc(chr : Char)
        @db.allocate_page(chr)
      end

      def put(page : PageRef)
        @db.write_page(page)
      end

      def get(pos : UInt32)
        @db.read_page(pos)
      end

      def del(pos : UInt32)
        @db.delete_page(pos)
      end
    end

    struct Reader
      def initialize(@db : DatabaseFile, @version : Int32)
      end

      def get(pos : UInt32)
        if @version < 0
          @db.read_page(pos)
        else
          @db.read_page_upto_version(pos, @version.to_u32)
        end
      end
    end

    def write
      writter = Writter.new(self)
      begin
        yield writter
      rescue ex
        rollback
        raise ex
      else
        commit
      end
      flush
    end

    def read
      current_version = @wal.size + @wal_skip
      @wal_usage[current_version - @wal_skip] += 1
      reader = Reader.new(self, current_version)
      begin
        yield reader
      ensure
        @wal_usage[current_version - @wal_skip] -= 1
      end
      flush
    end

    def debug
      puts "\nMain:"
      @page_count.times do |pos|
        read_page(pos).debug
      end
      puts "\nWAL:"
      skip = read_wal_page(0u32).as_wal.value.skip_page_count
      (skip...@wal_count).each do |wpos|
        read_wal_page(wpos).debug
      end
    end

    def flush
      return if @wal_count - @skip < 100
      flush!
    end

    def flush!
      while @wal_usage.size > 1 && @wal_usage[0] == 0
        (@skip...@wal_count).each do |wpos|
          page = read_wal_page(wpos)
          if page.type == 'C'
            ArchUtils.sync_file(@file)
            @skip = wpos + 1
            if @skip == @wal_count
              @skip = 1u32
              @wal_count = 1u32

              wal_page = read_wal_page(0u32)
              wal_page.as_wal.value.skip_page_count = @skip
              @wal_file.seek(0u32)
              @wal_file.write(Bytes.new(wal_page.pointer, @page_size))
              ArchUtils.sync_file(@wal_file)

              ArchUtils.truncate_file(@wal_file, (@wal_count + 1).to_u64 * @page_size)
            else
              wal_page = read_wal_page(0u32)
              wal_page.as_wal.value.skip_page_count = @skip
              @wal_file.seek(0u32)
              @wal_file.write(Bytes.new(wal_page.pointer, @page_size))
            end

            @wal_skip += 1
            @wal.shift
            @wal_usage.shift

            ArchUtils.punch_hole_in_file(@wal_file, @page_size, (@skip - 1).to_u64 * @page_size)
            break
          else
            @file.seek(page.pos * @page_size)
            @file.write(Bytes.new(page.pointer, @page_size))
            @real_page_count = Math.max(@real_page_count, page.pos + 1)
          end
        end
      end
    end

    def write_page(page)
      if wpos = @next_wal[page.pos]?
        @pending_wal[wpos] = Bytes.new(page.pointer, @page_size).clone
      else
        @pending_wal[@wal_count] = Bytes.new(page.pointer, @page_size).clone
        @next_wal[page.pos] = @wal_count
        @wal_count += 1
      end
    end

    def commit
      @pending_wal.each do |(wpos, bytes)|
        @wal_file.seek(wpos * @page_size)
        @wal_file.write(bytes)
      end
      @pending_wal = Hash(UInt32, Bytes).new

      ptr = Pointer(UInt8).malloc(@page_size)
      page = ptr.as(CommitPage*)
      page.value.type = 'C'.ord.to_u8

      @wal_file.seek(@wal_count * @page_size)
      @wal_file.write(Bytes.new(ptr, @page_size))
      @wal_count += 1

      @wal << @next_wal
      @wal_usage << 0u32
      @next_wal = Hash(UInt32, UInt32).new

      ArchUtils.sync_file(@wal_file)
    end

    def rollback
      @wal_count -= @next_wal.size
      @next_wal = Hash(UInt32, UInt32).new
    end

    def delete_page(pos : UInt32)
      if pos > @page_count
        raise Error.new("Writting page #{pos} out of bounds")
      end

      header_page_ref = read_page(0u32)

      page_ref = PageRef.new(Bytes.new(@page_size))
      page = page_ref.as_any
      page.value.type = 'F'.ord.to_u8
      page.value.pos = pos
      page_ref.as_free.value.next_free_page = @first_free_page
      @first_free_page = header_page_ref.as_header.value.first_free_page = pos

      write_page(page_ref)
      write_page(header_page_ref)
    end

    def allocate_page(chr : Char)
      if @first_free_page == 0
        page_ref = PageRef.new(Bytes.new(@page_size))
        page = page_ref.as_any
        page.value.type = chr.ord.to_u8
        page.value.pos = @page_count
        write_page(page_ref)
        @page_count += 1
        page_ref
      else
        free_page_ref = read_page(@first_free_page)
        header_page_ref = read_page(0u32)
        @first_free_page = header_page_ref.as_header.value.first_free_page = free_page_ref.as_free.value.next_free_page
        free_page_ref.as_any.value.type = chr.ord.to_u8
        write_page(header_page_ref)
        write_page(free_page_ref)
        free_page_ref
      end
    end

    def read_page(pos : UInt32)
      if wpos = @next_wal[pos]?
        return read_wal_page(wpos)
      end
      @wal.reverse_each do |table|
        if wpos = table[pos]?
          return read_wal_page(wpos)
        end
      end

      read_file_page(pos)
    end

    def read_page_upto_version(pos : UInt32, version : UInt32)
      current_version = @wal.size + @wal_skip
      skip = current_version - version
      @wal.reverse_each.skip(skip).each do |table|
        if wpos = table[pos]?
          return read_wal_page(wpos)
        end
      end

      read_file_page(pos)
    end

    def read_file_page(pos : UInt32)
      if pos > @real_page_count
        raise Error.new("Reading page #{pos} out of bounds")
      end
      slice = Bytes.new(@page_size)
      @file.pos = @page_size * pos
      @file.read(slice)
      PageRef.new(slice)
    end

    def read_wal_page(pos : UInt32)
      if pos > @wal_count
        raise Error.new("Reading page #{pos} out of bounds")
      end
      if slice = @pending_wal[pos]?
        return PageRef.new(slice.clone)
      end
      slice = Bytes.new(@page_size)
      @wal_file.pos = @page_size * pos
      @wal_file.read(slice)
      PageRef.new(slice)
    end

    def self.open(path : String)
      file = File.new(path + ".dat", "r+")
      walfile = File.new(path + ".wal", "r+")
      return new(file, walfile)
    end

    def self.create(path : String, options : CreateOptions = CreateOptions.new)
      if File.exists?(path + ".dat")
        raise Error.new("File '#{path}' already exists")
      end

      file = File.new(path + ".dat", "w+")
      ArchUtils.grow_sparse_file(file, 1u64 * options.page_size)

      header = HeaderPage.new
      header.type = 'H'.ord.to_u8
      header.page_size = options.page_size
      file.write Bytes.new(pointerof(header).as UInt8*, sizeof(HeaderPage))

      wal_file = File.new(path + ".wal", "w+")
      ArchUtils.grow_sparse_file(wal_file, 1u64 * options.page_size)

      wal_start = WalStartPage.new
      wal_start.type = 'W'.ord.to_u8
      wal_start.skip_page_count = 1u32
      wal_file.write Bytes.new(pointerof(wal_start).as UInt8*, sizeof(WalStartPage))

      return new(file, wal_file)
    end

    struct CreateOptions
      property page_size = 4096u16
    end
  end
end
