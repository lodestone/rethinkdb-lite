require "spec"
require "../../src/reql/*"

include ReQL::DSL

describe ReQL do
  it "maps datum array to datum array" do
    r([1, 2, 3]).map { |x| x }.run.value.should eq (1..3).to_a
    r([1, 2, 3]).map { |x| {"value" => x.as(R::Type)}.as(R::Type) }.run.value.should eq (1..3).map { |x| {"value" => x} }
    r([1, 2, 3]).map { |x| x }.count.run.value.should eq 3
  end

  it "maps stream to stream" do
    r.range(1, 4).map { |x| x }.run.value.should eq (1..3).to_a
    r.range(1, 4).map { |x| {"value" => x.as(R::Type)}.as(R::Type) }.run.value.should eq (1..3).map { |x| {"value" => x} }
    r.range(1, 4).map { |x| x }.count.run.value.should eq 3
  end

  it "maps into a stream (which is coerced into array)" do
    r.range(1, 10).map { |x| r.range(0, x) }.run.value.should eq (1...10).map { |i| (0...i).to_a }
  end

  it "counts across map" do
    r.range(10000).map { |x| x }.count.run.value.should eq 10000
  end

  it "can map an infinite stream" do
    stream = r.range.map { |x| [x.as(R::Type)].as(R::Type) }.run.as ReQL::Stream
    stream.start_reading
    1000.times do |i|
      stream.next_val.should eq({[i.to_i64]})
    end
    stream.finish_reading
  end
end