require "../database_file"
require "../btree"
require "../../reql/error"
require "json"

module Storage
  class StoredTable < AbstractTable
    @file : DatabaseFile

    def self.create(path : String)
      db = DatabaseFile.create(path)
      btree = nil
      db.write do |w|
        btree = BTree.create(w)

        header = w.get(0u32)
        header.as_header.value.table_btree_pos = btree.pos
        w.put(header)
      end

      new db, btree.not_nil!
    end

    def self.open(path : String)
      db = DatabaseFile.open(path)
      btree_pos = 0u32
      db.read do |r|
        btree_pos = r.get(0u32).as_header.value.table_btree_pos
      end

      new db, BTree.new(btree_pos)
    end

    def close
      @file.close
    end

    def initialize(@file : DatabaseFile, @btree : BTree)
    end

    def insert(obj : Hash(String, ReQL::Datum::Type))
      k = BTree.make_key obj["id"]
      @file.write do |w|
        pos = @btree.query(w.reader, k)
        if pos != 0
          row = Data.new(w.get(pos)).read(w.reader)
          pretty_row = JSON.build(4) { |builder| ReQL::Datum.wrap(row).to_json(builder) }
          pretty_obj = JSON.build(4) { |builder| ReQL::Datum.wrap(obj).to_json(builder) }
          raise ReQL::OpFailedError.new("Duplicate primary key `id`:\n#{pretty_row}\n#{pretty_obj}")
        end
        data = Data.create(w, obj)
        old_pos = @btree.pos
        @btree.insert(w, k, data.pos)
        if @btree.pos != old_pos
          header = w.get(0u32)
          header.as_header.value.table_btree_pos = @btree.pos
          w.put(header)
        end
      end
    end

    def get(key : ReQL::Datum::Type)
      k = BTree.make_key key
      row = nil
      @file.read do |r|
        pos = @btree.query(r, k)
        if pos != 0u32
          row = Data.new(r.get(pos)).read(r).as(Hash(String, ReQL::Datum::Type))
        end
      end
      row
    end

    def replace(key : ReQL::Datum::Type)
      k = BTree.make_key key
      row = nil
      @file.write do |w|
        pos = @btree.query(w.reader, k)
        if pos == 0u32
          new_row = yield nil
          data = Data.create(w, new_row)
          old_pos = @btree.pos
          @btree.insert(w, k, data.pos)
          if @btree.pos != old_pos
            header = w.get(0u32)
            header.as_header.value.table_btree_pos = @btree.pos
            w.put(header)
          end
        else
          data = Data.new(w.get(pos))
          old_row = data.read(w.reader).as?(Hash)
          new_row = yield old_row
          data.write(w, new_row)
        end
      end
      row
    end

    def scan(&block : Hash(String, ReQL::Datum::Type) ->)
      @file.read do |r|
        @btree.scan(r) do |pos|
          row = Data.new(r.get(pos)).read(r).as(Hash(String, ReQL::Datum::Type))
          block.call row
        end
      end
    end

    def count
      count = 0i64
      @file.read do |r|
        count = @btree.count(r)
      end
      count
    end
  end
end
