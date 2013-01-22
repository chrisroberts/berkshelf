require 'spec_helper'

module Berkshelf
  describe Resolver, :chef_server do
    let(:source) do
      double('source',
        name: 'mysql',
        version_constraint: Solve::Constraint.new('= 1.2.4'),
        downloaded?: true,
        cached_cookbook: double('mysql-cookbook',
          name: 'mysql-1.2.4',
          cookbook_name: 'mysql',
          version: '1.2.4',
          dependencies: { "nginx" => ">= 0.1.0", "artifact" => "~> 0.10.0" }
        ),
        location: double('location', validate_cached: true)
      )
    end

    let(:source_two) do
      double('source-two',
        name: 'nginx',
        version_constraint: Solve::Constraint.new('= 0.101.2'),
        downloaded?: true,
        cached_cookbook: double('nginx-cookbook',
          name: 'nginx-0.101.2',
          cookbook_name: 'nginx',
          version: '0.101.2',
          dependencies: Hash.new
        ),
        location: double('location', validate_cached: true)
      )
    end

    let(:source_three) do
      double('source-three',
        name: 'thing1',
        version_constraint: Solve::Constraint.new('= 0.1.0'),
        downloaded?: true,
        cached_cookbook: double('thing1-cookbook',
          name: 'thing1-0.1.0',
          cookbook_name: 'thing1',
          version: '0.1.0',
          dependencies: Hash.new
        ),
        location: double('location', validate_cached: true)
      )
    end

    describe "ClassMethods" do
      subject { Resolver }

      describe "::initialize" do
        let(:downloader) { Downloader.new(Berkshelf.cookbook_store) }

        it "adds the specified sources to the sources hash" do
          resolver = subject.new(downloader, sources: source)

          resolver.should have_source(source.name)
        end

        it "adds the dependencies of the source as sources" do
          resolver = subject.new(downloader, sources: source)

          resolver.should have_source("nginx")
          resolver.should have_source("artifact")
        end

        it "should not add dependencies if requested" do
          resolver = subject.new(downloader, sources: source, skip_dependencies: true)

          resolver.should_not have_source("nginx")
          resolver.should_not have_source("artifact")
        end

        context "given the nested_berksfiles option" do

          it "should process Berksfiles found within sources of original Berksfile" do
            berksfile = Berkshelf::Berksfile.from_file(
              fixtures_path.join('Berksfile.nested')
            )
            resolver = subject.new(downloader, sources: berksfile.sources, nested_berksfiles: true)
            resolver.should have_source('example_with_berksfile')
            resolver.should have_source('example_cookbook')
          end

          it "should properly handle circular dependencies within nested Berksfiles" do
            berksfile = Berkshelf::Berksfile.from_file(
              fixtures_path.join('Berksfile.circular')
            )
            resolver = subject.new(downloader, sources: berksfile.sources, nested_berksfiles: true)
            resolver.should have_source('example_cookbook')
            resolver.should have_source('example_with_berksfile_circle1')
            resolver.should have_source('example_with_berksfile_circle2')
          end

        end

        context "given the nested_berksfiles option" do
          let(:berksfile) do
          end

        end

        context "given an array of sources" do
          it "adds each source to the sources hash" do
            sources = [source]
            resolver = subject.new(downloader, sources: sources)

            resolver.should have_source(sources[0].name)
          end
        end
      end
    end

    let(:downloader) { Downloader.new(Berkshelf.cookbook_store) }
    subject { Resolver.new(downloader) }

    describe "#add_source" do
      let(:package_version) { double('package-version', dependencies: Array.new) }

      it "adds the source to the instance of resolver" do
        subject.add_source(source)

        subject.sources.should include(source)
      end

      it "adds an artifact of the same name of the source to the graph" do
        subject.graph.should_receive(:artifacts).with(source.name, source.cached_cookbook.version)

        subject.add_source(source, false)
      end

      it "adds the dependencies of the source as packages to the graph" do
        subject.should_receive(:add_source_dependencies).with(source)

        subject.add_source(source)
      end

      it "raises a DuplicateSourceDefined exception if a source of the same name is added" do
        subject.should_receive(:has_source?).with(source).and_return(true)

        lambda {
          subject.add_source(source)
        }.should raise_error(DuplicateSourceDefined)
      end

      context "when include_dependencies is false" do
        it "does not try to include_dependencies" do
          subject.should_not_receive(:add_source_dependencies)

          subject.add_source(source, false)
        end
      end
    end

    describe "#get_source" do
      before(:each) { subject.add_source(source) }

      context "given a string representation of the source to retrieve" do
        it "returns the source of the same name" do
          subject.get_source(source.name).should eql(source)
        end
      end
    end

    describe "#has_source?" do
      before(:each) { subject.add_source(source) }

      it "returns the source of the given name" do
        subject.has_source?(source.name).should be_true
      end
    end

    describe "#resolve" do
      before(:each) do
        [source_three, source_two, source].each do |s|
          subject.add_source(s)
        end
      end

      it "returns all cookbooks" do
        solution = subject.resolve
        solution.should include(source.cached_cookbook)
        solution.should include(source_two.cached_cookbook)
        solution.should include(source_three.cached_cookbook)
      end

      it "returns cookbook and its dependencies" do
        solution = subject.resolve(['mysql'])
        solution.should include(source.cached_cookbook)
        solution.should include(source_two.cached_cookbook)
      end

      it "returns the cookbook only if there are no dependencies" do
        solution = subject.resolve(['thing1'])
        solution.should have(1).items
        solution.should include(source_three.cached_cookbook)
      end
    end
  end
end
