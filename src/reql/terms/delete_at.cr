module ReQL
  class DeleteAtTerm < Term
    register_type DELETE_AT
    infix_inspect "delete_at"

    def compile
      expect_args 2, 3
    end
  end

  class Evaluator
    def eval(term : DeleteAtTerm)
      arr = eval term.args[0]
      expect_type arr, DatumArray
      arr = arr.value

      idx = eval term.args[1]
      unless idx.is_a? DatumNumber
        raise NonExistenceError.new("Expected type #{DatumNumber.reql_name} but found #{idx.class.reql_name}.")
      end
      idx = idx.to_i64

      if term.args.size == 2
        if idx >= arr.size
          raise NonExistenceError.new "Index `#{idx}` out of bounds for array of size: `#{arr.size}`."
        end

        if idx < 0
          old_idx = idx
          idx += arr.size

          if idx < 0 || idx >= arr.size
            raise NonExistenceError.new "Index out of bounds: #{old_idx}"
          end
        end

        arr = arr.dup
        arr.delete_at idx
        DatumArray.new(arr)
      else
        end_idx = eval term.args[2]
        expect_type end_idx, DatumNumber
        end_idx = end_idx.to_i64

        if idx >= arr.size && idx != end_idx
          raise NonExistenceError.new "Index `#{idx}` out of bounds for array of size: `#{arr.size}`."
        end

        if idx < 0
          old_idx = idx
          idx += arr.size

          if idx < 0 || (idx >= arr.size && idx != end_idx)
            raise NonExistenceError.new "Index out of bounds: #{old_idx}"
          end
        end

        if end_idx > arr.size
          raise NonExistenceError.new "Index `#{end_idx}` out of bounds for array of size: `#{arr.size}`."
        end

        if end_idx < 0
          old_end_idx = end_idx
          end_idx += arr.size

          if end_idx < idx || end_idx > arr.size
            raise NonExistenceError.new "Index out of bounds: #{old_idx}"
          end
        end

        arr = arr.dup
        arr.delete_at idx...end_idx
        DatumArray.new(arr)
      end
    end
  end
end
