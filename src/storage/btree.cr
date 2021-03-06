require "./database_file"
require "digest"

struct StaticArray(T, N)
  include Comparable(StaticArray(T, N))

  def <=>(other : StaticArray(T, N))
    0.upto(size - 1) do |i|
      n = to_unsafe[i] <=> other.to_unsafe[i]
      return n if n != 0
    end
    0
  end
end

module Storage
  struct BTree
    alias Key = StaticArray(UInt8, 20)

    def initialize(@root : UInt32)
    end

    def pos
      @root
    end

    def self.create(w : DatabaseFile::Writter)
      new(w.alloc('b').pos)
    end

    def self.make_key(obj)
      return Digest::SHA1.digest(ReQL::Datum.wrap(obj).serialize)
    end

    def list_offset
      x = BTreeLeafPage.new
      pointerof(x.@list).address - pointerof(x).address
    end

    def node_offset
      x = BTreeNodePage.new
      pointerof(x.@list).address - pointerof(x).address
    end

    def insert(w : DatabaseFile::Writter, key : Key, value : UInt32)
      page = w.get(@root)
      if pair = insert_at_page(w, page, key, value)
        key, value = pair

        new_page = w.alloc('B')
        new_root = new_page.as_node
        new_root.value.count = 2u8
        new_root.value.list.to_unsafe[0] = {Key.new(0u8), @root}
        new_root.value.list.to_unsafe[1] = {key, value}
        @root = new_page.pos
        w.put(new_page)
      end
    end

    private def insert_at_page(w : DatabaseFile::Writter, page : PageRef, key : Key, value : UInt32)
      if page.type == 'b'
        leaf = page.as_leaf
        max_count = {255, ((page.size - list_offset) / (sizeof(Key) + 4)).to_i}.min

        arr = [] of {Key, UInt32}
        leaf.value.count.times do |i|
          arr << leaf.value.list.to_unsafe[i]
        end
        arr << {key, value}
        arr.sort_by! { |e| e[0] }

        if arr.size > max_count
          new_page = w.alloc('b')
          new_leaf = new_page.as_leaf
          new_leaf.value.succ = leaf.value.succ
          new_leaf.value.prev = page.pos
          leaf.value.succ = new_page.pos

          size1 = arr.size/2
          arr.each_with_index do |e, i|
            if i < size1
              leaf.value.list.to_unsafe[i] = e
            else
              new_leaf.value.list.to_unsafe[i - size1] = e
            end
          end

          leaf.value.count = (size1).to_u8
          new_leaf.value.count = (arr.size - size1).to_u8

          w.put(page)
          w.put(new_page)

          {new_leaf.value.list.to_unsafe[0][0], new_page.pos}
        else
          arr.each_with_index do |e, i|
            leaf.value.list.to_unsafe[i] = e
          end

          leaf.value.count = leaf.value.count + 1
          w.put(page)

          nil
        end
      else
        node = page.as_node

        max_count = {255, ((page.size - node_offset) / (sizeof(Key) + 4)).to_i}.min

        target_pos = 0u32
        node.value.count.times do |i|
          if key >= node.value.list.to_unsafe[i][0]
            target_pos = node.value.list.to_unsafe[i][1]
          else
            break
          end
        end

        if pair = insert_at_page(w, w.get(target_pos), key, value)
          key, value = pair

          arr = [] of {Key, UInt32}
          node.value.count.times do |i|
            arr << node.value.list.to_unsafe[i]
          end
          arr << {key, value}
          arr.sort_by! { |e| e[0] }

          if arr.size > max_count
            new_page = w.alloc('B')
            new_node = new_page.as_node

            size1 = arr.size/2
            arr.each_with_index do |e, i|
              if i < size1
                node.value.list.to_unsafe[i] = e
              else
                new_node.value.list.to_unsafe[i - size1] = e
              end
            end

            node.value.count = size1.to_u8
            new_node.value.count = (arr.size - size1).to_u8

            w.put(page)
            w.put(new_page)

            {arr[size1][0], new_page.pos}
          else
            arr.each_with_index do |e, i|
              node.value.list.to_unsafe[i] = e
            end

            node.value.count = node.value.count + 1
            w.put(page)

            nil
          end
        else
          nil
        end
      end
    end

    def query(r : DatabaseFile::Reader, key : Key)
      query_at_page(r, r.get(@root), key)
    end

    def query_at_page(r : DatabaseFile::Reader, page : PageRef, key : Key)
      if page.type == 'b'
        leaf = page.as_leaf

        leaf.value.count.times do |i|
          if leaf.value.list.to_unsafe[i][0] == key
            return leaf.value.list.to_unsafe[i][1]
          end
        end
      else
        node = page.as_node
        target_pos = 0u32
        node.value.count.times do |i|
          if key >= node.value.list.to_unsafe[i][0]
            target_pos = node.value.list.to_unsafe[i][1]
          else
            break
          end
        end

        return query_at_page(r, r.get(target_pos), key)
      end
      0u32
    end

    private def find_first_leaf(r : DatabaseFile::Reader, page : PageRef)
      while page.type == 'B'
        page = r.get(page.as_node.value.list.to_unsafe[0][1])
      end

      return page
    end

    private def each_leaf(r : DatabaseFile::Reader)
      page = find_first_leaf(r, r.get(@root))
      loop do
        leaf = page.as_leaf
        yield leaf

        succ = leaf.value.succ
        break if succ == 0
        page = r.get(succ)
      end
    end

    def scan(r : DatabaseFile::Reader)
      each_leaf(r) do |leaf|
        leaf.value.count.times do |i|
          yield leaf.value.list.to_unsafe[i][1]
        end
      end
    end

    def count(r : DatabaseFile::Reader)
      result = 0i64
      each_leaf(r) do |leaf|
        result += leaf.value.count
      end
      result
    end
  end
end
