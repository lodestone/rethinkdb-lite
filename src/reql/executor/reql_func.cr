module ReQL
  class ReqlFunc < Func
    def self.reql_name
      "FUNCTION"
    end

    def initialize(@vars : Array(Int64), @func : Term::Type)
    end

    def eval(evaluator : Evaluator, *args)
      evaluator = evaluator.dup
      args = args.to_a + [] of Datum
      if @vars.size > args.size
        raise QueryLogicError.new("Function expects #{@vars.size} arguments, but only #{args.size} available")
      end
      @vars.each.with_index do |var, i|
        evaluator.vars[var] = args[i]
      end
      evaluator.eval(@func)
    end
  end
end
