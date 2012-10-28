

require 'spec_helper'
require 'gorg/application'
require 'rack'

describe Gorg::Application do
  subject { Gorg::Application.new }

  let(:environment) { mock('environment') }

  before do
    $Config = {'root' => 'root path'}
  end

  it { should_not be_nil }

  pending "More fine-grained code that can be tested piece by piece" do
    specify { subject.call(environment).should be_a_kind_of Array }
    specify { subject.call(environment).size.should == 3 }

    specify { subject.call(environment)[0].should be_a_kind_of Integer }
    specify { subject.call(environment)[1].should be_a_kind_of Hash }
    specify { subject.call(environment)[2].should be_a_kind_of Array }
  end

end
