# EARL reporting
require 'linkeddata'
require 'sparql'
require 'haml'
require 'open-uri'

##
# EARL reporting class.
# Instantiate a new class using one or more input graphs
class EarlReport
  autoload :VERSION, 'earl_report/version'

  attr_reader :graph

  # Return information about each test.
  # Tests all have an mf:action property.
  # The Manifest lists all actions in list from mf:entries
  MANIFEST_QUERY = %(
    PREFIX mf: <http://www.w3.org/2001/sw/DataAccess/tests/test-manifest#>
    PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>

    SELECT ?uri ?testAction ?manUri
    WHERE {
      ?uri mf:action ?testAction .
      OPTIONAL {
        ?manUri a mf:Manifest; mf:entries ?lh .
        ?lh rdf:first ?uri .
      }
    }
  ).freeze

  TEST_SUBJECT_QUERY = %(
    PREFIX doap: <http://usefulinc.com/ns/doap#>
    PREFIX foaf: <http://xmlns.com/foaf/0.1/>

    SELECT DISTINCT ?uri ?name ?doapDesc ?homepage ?language ?developer ?devName ?devType ?devHomepage
    WHERE {
      ?uri a doap:Project; doap:name ?name; doap:developer ?developer .
      OPTIONAL { ?uri doap:homepage ?homepage . }
      OPTIONAL { ?uri doap:description ?doapDesc . }
      OPTIONAL { ?uri doap:programming-language ?language . }
      OPTIONAL { ?developer a ?devType .}
      OPTIONAL { ?developer foaf:name ?devName .}
      OPTIONAL { ?developer foaf:homepage ?devHomepage .}
    }
    ORDER BY ?name
  ).freeze

  DOAP_QUERY = %(
    PREFIX earl: <http://www.w3.org/ns/earl#>
    PREFIX doap: <http://usefulinc.com/ns/doap#>
    
    SELECT DISTINCT ?subject ?name
    WHERE {
      [ a earl:Assertion; earl:subject ?subject ] .
      OPTIONAL {
        ?subject a doap:Project; doap:name ?name
      }
    }
  ).freeze

  ASSERTION_QUERY = %(
    PREFIX earl: <http://www.w3.org/ns/earl#>
    
    SELECT ?test ?subject ?by ?mode ?outcome
    WHERE {
      ?a a earl:Assertion;
        earl:assertedBy ?by;
        earl:result [earl:outcome ?outcome];
        earl:subject ?subject;
        earl:test ?test .
      OPTIONAL {
        ?a earl:mode ?mode .
      }
    }
    ORDER BY ?subject
  ).freeze

  TEST_FRAME = {
    "@context" => {
      "@vocab" =>   "http://www.w3.org/ns/earl#",
      "foaf:homepage" => {"@type" => "@id"},
      "dc" =>           "http://purl.org/dc/terms/",
      "doap" =>         "http://usefulinc.com/ns/doap#",
      "earl" =>         "http://www.w3.org/ns/earl#",
      "mf" =>           "http://www.w3.org/2001/sw/DataAccess/tests/test-manifest#",
      "foaf" =>         "http://xmlns.com/foaf/0.1/",
      "rdfs" =>         "http://www.w3.org/2000/01/rdf-schema#",
      "assertedBy" =>   {"@type" => "@id"},
      "assertions" =>   {"@type" => "@id", "@container" => "@set"},
      "bibRef" =>       {"@id" => "dc:bibliographicCitation"},
      "created" =>      {"@id" => "doap:created", "@type" => "xsd:date"},
      "description" =>  {"@id" => "rdfs:comment", "@language" => "en"},
      "developer" =>    {"@id" => "doap:developer", "@type" => "@id", "@container" => "@set"},
      "doapDesc" =>     {"@id" => "doap:description", "@language" => "en"},
      "generatedBy" =>  {"@type" => "@id"},
      "homepage" =>     {"@id" => "doap:homepage", "@type" => "@id"},
      "language" =>     {"@id" => "doap:programming-language"},
      "license" =>      {"@id" => "doap:license", "@type" => "@id"},
      "mode" =>         {"@type" => "@id"},
      "name" =>         {"@id" => "doap:name"},
      "outcome" =>      {"@type" => "@id"},
      "release" =>      {"@id" => "doap:release", "@type" => "@id"},
      "revision" =>     {"@id" => "doap:revision"},
      "shortdesc" =>    {"@id" => "doap:shortdesc", "@language" => "en"},
      "subject" =>      {"@type" => "@id"},
      "test" =>         {"@type" => "@id"},
      "testAction" =>   {"@id" => "mf:action", "@type" => "@id"},
      "testResult" =>   {"@id" => "mf:result", "@type" => "@id"},
      "title" =>        {"@id" => "mf:name"},
      "entries" =>      {"@id" => "mf:entries", "@type" => "@id", "@container" => "@list"},
      "testSubjects" => {"@type" => "@id", "@container" => "@set"},
      "xsd" =>          {"@id" => "http://www.w3.org/2001/XMLSchema#"}
    },
    "@requireAll" => true,
    "@embed" => "@always",
    "assertions" => {},
    "bibRef" => {},
    "generatedBy" => {
      "@embed" => "@always",
      "developer" => {"@embed" => "@always"},
      "release" => {"@embed" => "@always"}
    },
    "testSubjects" => {
      "@embed" => "@always",
      "@type" => "earl:TestSubject",
      "developer" => {"@embed" => "@always"},
      "homepage" => {"@embed" => "@never"}
    },
    "entries" => [{
      "@embed" => "@always",
      "@type" => "mf:Manifest",
      "entries" => [{
        "@embed" => "@always",
        "@type" => "earl:TestCase",
        "assertions" => {
          "@embed" => "@always",
          "@type" => "earl:Assertion",
          "assertedBy" => {"@embed" => "@never"},
          "result" => {
            "@embed" => "@always",
            "@type" => "earl:TestResult"
          },
          "subject" => {"@embed" => "@never"}
        }
      }]
    }]
  }.freeze

  # Convenience vocabularies
  class EARL < RDF::Vocabulary("http://www.w3.org/ns/earl#"); end
  class MF < RDF::Vocabulary("http://www.w3.org/2001/sw/DataAccess/tests/test-manifest#"); end

  ##
  # Load test assertions and look for referenced software and developer information
  # @overload initialize(*files)
  #   @param [Array<String>] files Assertions
  # @overload initialize(*files, options = {})
  #   @param [Hash{Symbol => Object}] options
  #   @option options [Boolean] :verbose (true)
  #   @option options [String] :base Base IRI for loading Manifest
  #   @option options [String] :bibRef
  #     ReSpec bibliography reference for specification being tested
  #   @option options [String] :json Result of previous JSON-LD generation
  #   @option options [String, Array<String>] :manifest Test manifest
  #   @option options [String] :name Name of specification
  #   @option options [String] :query
  #     Query, or file containing query for extracting information from Test manifests
  def initialize(*files)
    @options = files.last.is_a?(Hash) ? files.pop.dup : {}
    @options[:query] ||= MANIFEST_QUERY
    raise "Test Manifests must be specified with :manifest option" unless @options[:manifest] || @options[:json]
    raise "Require at least one input file" if files.empty?
    @files = files
    @prefixes = {}

    # If provided :json, it is used for generating all other output forms
    if @options[:json]
      @json_hash = ::JSON.parse(File.read(files.first))
      # Add a base_uri so relative subjects aren't dropped
      JSON::LD::Reader.open(files.first, base_uri: "http://example.org/report") do |r|
        @graph = RDF::Graph.new
        r.each_statement do |statement|
          # restore relative subject
          statement.subject = RDF::URI("") if statement.subject == "http://example.org/report"
          @graph << statement
        end
      end
      return
    end

    # Load manifests, possibly with base URI
    status "read #{@options[:manifest].inspect}"
    man_opts = {}
    man_opts[:base_uri] = RDF::URI(@options[:base]) if @options[:base]
    @graph = RDF::Graph.new
    Array(@options[:manifest]).each do |man|
      g = RDF::Graph.load(man, unique_bnodes: true, **man_opts)
      status "  loaded #{g.count} triples from #{man}"
      graph << g
    end

    # Hash test cases by URI
    tests = SPARQL.execute(@options[:query], graph)
      .to_a
      .inject({}) {|memo, soln| memo[soln[:uri]] = soln; memo}

    if tests.empty?
      raise "no tests found querying manifest.\n" +
            "Results are found using the following query, this can be overridden using the --query option:\n" +
            "#{@options[:query]}"
    end

    # Manifests in graph
    man_uris = tests.values.map {|v| v[:manUri]}.uniq.compact
    test_resources = tests.values.map {|v| v[:uri]}.uniq.compact
    subjects = {}

    assertion_graph = RDF::Graph.new
    # Read test assertion files into assertion graph
    files.flatten.each do |file|
      status "read #{file}"
      file_graph = RDF::Graph.load(file)
      if file_graph.first_object(predicate: RDF::URI('http://www.w3.org/ns/earl#testSubjects'))
        status "   skip #{file}, which seems to be a previous rollup earl report"
        @files -= [file]
      else
        status "  loaded #{file_graph.count} triples"

        # Find or load DOAP descriptions for all subjects
        SPARQL.execute(DOAP_QUERY, file_graph).each do |solution|
          subject = solution[:subject]

          # Load DOAP definitions
          unless solution[:name] # not loaded
            status "read doap description for #{subject}"
            begin
              doap_graph = RDF::Graph.load(subject)
              status "  loaded #{doap_graph.count} triples"
              file_graph << doap_graph.to_a
            rescue
              warn "\nfailed to load DOAP from #{subject}: #{$!}"
            end
          end
        end

        # Sanity check loaded graph, look for test subject
        solutions = SPARQL.execute(TEST_SUBJECT_QUERY, file_graph)
        if solutions.empty?
          warn "\nTest subject info not found for #{file}, expect DOAP description of project solving the following query:\n" +
            TEST_SUBJECT_QUERY
          next
        end

        # Load developers referenced from Test Subjects
        if !solutions.first[:developer]
          warn "\nNo developer identified for #{solutions.first[:uri]}"
        elsif !solutions.first[:devName]
          status "read description for developer #{solutions.first[:developer].inspect}"
          begin
            foaf_graph = RDF::Graph.load(solutions.first[:developer])
            status "  loaded #{foaf_graph.count} triples"
            file_graph << foaf_graph.to_a
            # Reload solutions
            solutions = SPARQL.execute(TEST_SUBJECT_QUERY, file_graph)
          rescue
            warn "\nfailed to load FOAF from #{solutions.first[:developer]}: #{$!}"
          end
        end

        solutions.each do |solution|
          # Kepp track of subjects
          subjects[solution[:uri]] = RDF::URI(file)

          # Add TestSubject information to main graph
          name = solution[:name].to_s if solution[:name]
          language = solution[:language].to_s if solution[:language]
          doapDesc = solution[:doapDesc] if solution[:doapDesc]
          doapDesc.language ||= :en if doapDesc
          devName = solution[:devName].to_s if solution[:devName]
          graph << RDF::Statement(solution[:uri], RDF.type, RDF::Vocab::DOAP.Project)
          graph << RDF::Statement(solution[:uri], RDF.type, EARL.TestSubject)
          graph << RDF::Statement(solution[:uri], RDF.type, EARL.Software)
          graph << RDF::Statement(solution[:uri], RDF::Vocab::DOAP.name, name)
          graph << RDF::Statement(solution[:uri], RDF::Vocab::DOAP.developer, solution[:developer])
          graph << RDF::Statement(solution[:uri], RDF::Vocab::DOAP.homepage, solution[:homepage]) if solution[:homepage]
          graph << RDF::Statement(solution[:uri], RDF::Vocab::DOAP.description, doapDesc) if doapDesc
          graph << RDF::Statement(solution[:uri], RDF::Vocab::DOAP[:"programming-language"], language) if solution[:language]
          graph << RDF::Statement(solution[:developer], RDF.type, solution[:devType]) if solution[:devType]
          graph << RDF::Statement(solution[:developer], RDF::Vocab::FOAF.name, devName) if devName
          graph << RDF::Statement(solution[:developer], RDF::Vocab::FOAF.homepage, solution[:devHomepage]) if solution[:devHomepage]
        end

        assertion_graph << file_graph
      end
    end

    # Make sure that each assertion matches a test and add reference from test to assertion
    found_solutions = {}

    # Initialize test assertions with an entry for each test subject
    test_assertion_lists = {}
    test_assertion_lists = tests.keys.inject({}) do |memo, test|
      memo.merge(test => Array.new(subjects.length))
    end

    status "query assertions"
    assertion_stats = {}
    SPARQL.execute(ASSERTION_QUERY, assertion_graph).each do |solution|
      subject = solution[:subject]
      unless tests[solution[:test]]
        assertion_stats["Skipped"] = assertion_stats["Skipped"].to_i + 1
        $stderr.puts "Skipping result for #{solution[:test]} for #{subject}, which is not defined in manifests"
        next
      end
      unless subjects[subject]
        assertion_stats["Missing Subject"] = assertion_stats["Missing Subject"].to_i + 1
        $stderr.puts "No test result subject found for #{subject}: in #{subjects.keys.join(', ')}"
        next
      end
      found_solutions[subject] = true
      assertion_stats["Found"] = assertion_stats["Found"].to_i + 1

      # Add this solution at the appropriate index within that list
      ndx = subjects.keys.find_index(subject)
      ary = test_assertion_lists[solution[:test]] ||= []

      ary[ndx] = a = RDF::Node.new
      graph << RDF::Statement(a, RDF.type, EARL.Assertion)
      graph << RDF::Statement(a, EARL.subject, subject)
      graph << RDF::Statement(a, EARL.test, solution[:test])
      graph << RDF::Statement(a, EARL.assertedBy, solution[:by])
      graph << RDF::Statement(a, EARL.mode, solution[:mode]) if solution[:mode]
      r = RDF::Node.new
      graph << RDF::Statement(a, EARL.result, r)
      graph << RDF::Statement(r, RDF.type, EARL.TestResult)
      graph << RDF::Statement(r, EARL.outcome, solution[:outcome])
    end

    # Add ordered assertions for each test
    test_assertion_lists.each do |test, ary|
      # Fill any missing entries with an untested outcome
      ary.each_with_index do |a, ndx|
        unless a
          assertion_stats["Untested"] = assertion_stats["Untested"].to_i + 1
          ary[ndx] = a = RDF::Node.new
          graph << RDF::Statement(a, RDF.type, EARL.Assertion)
          graph << RDF::Statement(a, EARL.subject, subjects.keys[ndx])
          graph << RDF::Statement(a, EARL.test, test)
          r = RDF::Node.new
          graph << RDF::Statement(a, EARL.result, r)
          graph << RDF::Statement(r, RDF.type, EARL.TestResult)
          graph << RDF::Statement(r, EARL.outcome, EARL.untested)
        end

        # This counts on order being preserved in default repository so we can avoid using an rdf:List
        graph << RDF::Statement(test, EARL.assertions, a)
      end
    end

    assertion_stats.each {|stat, count| status("Assertions #{stat}: #{count}")}

    # See if any subject did not report results, which may indicate a formatting error in the EARL source
    subjects.reject {|s| found_solutions[s]}.each do |sub|
      $stderr.puts "No results found for #{sub} using #{ASSERTION_QUERY}"
    end

    # Add report wrapper to graph
    ttl = %(
      @prefix dc:   <http://purl.org/dc/terms/> .
      @prefix doap: <http://usefulinc.com/ns/doap#> .
      @prefix earl: <http://www.w3.org/ns/earl#> .
      @prefix mf:   <http://www.w3.org/2001/sw/DataAccess/tests/test-manifest#> .
      @prefix xsd:  <http://www.w3.org/2001/XMLSchema#> .

      <> a earl:Software, doap:Project;
      doap:name #{quoted(@options.fetch(:name, 'Unknown'))};
      dc:bibliographicCitation "#{@options.fetch(:bibRef, 'Unknown reference')}";
      earl:generatedBy <http://rubygems.org/gems/earl-report>;
      earl:assertions #{subjects.values.map {|f| f.to_ntriples}.join(",\n          ")};
      earl:testSubjects #{subjects.keys.map {|f| f.to_ntriples}.join(",\n          ")};
      mf:entries (#{man_uris.map {|f| f.to_ntriples}.join("\n          ")}) .

      <http://rubygems.org/gems/earl-report> a earl:Software, doap:Project;
         doap:name "earl-report";
         doap:shortdesc "Earl Report summary generator"@en;
         doap:description "EarlReport generates HTML+RDFa rollups of multiple EARL reports"@en;
         doap:homepage <https://github.com/gkellogg/earl-report>;
         doap:programming-language "Ruby";
         doap:license <http://unlicense.org>;
         doap:release <https://github.com/gkellogg/earl-report/tree/#{VERSION}>;
         doap:developer <http://greggkellogg.net/foaf#me> .

      <https://github.com/gkellogg/earl-report/tree/#{VERSION}> a doap:Version;
        doap:name "earl-report-#{VERSION}";
        doap:created "#{File.mtime(File.expand_path('../../VERSION', __FILE__)).strftime('%Y-%m-%d')}"^^xsd:date;
        doap:revision "#{VERSION}" .
    ).gsub(/^      /, '')
    RDF::Turtle::Reader.new(ttl) {|r| graph << r}

    # Each manifest is an earl:Report
    man_uris.each do |u|
      graph << RDF::Statement.new(u, RDF.type, EARL.Report)
    end

    # Each subject is an earl:TestSubject
    subjects.keys.each do |u|
      graph << RDF::Statement.new(u, RDF.type, EARL.TestSubject)
    end

    # Each assertion test is a earl:TestCriterion and earl:TestCase
    test_resources.each do |u|
      graph << RDF::Statement.new(u, RDF.type, EARL.TestCriterion)
      graph << RDF::Statement.new(u, RDF.type, EARL.TestCase)
    end
  end

  ##
  # Dump the coalesced output graph
  #
  # If no `io` option is provided, the output is returned as a string
  #
  # @param [Hash{Symbol => Object}] options
  # @option options [Symbol] format (:html)
  # @option options[IO] :io
  #   Optional `IO` to output results
  # @return [String] serialized graph, if `io` is nil
  def generate(options = {})
    options = {format: :html}.merge(options)

    io = options[:io]

    status("generate: #{options[:format]}")
    ##
    # Retrieve Hashed information in JSON-LD format
    case options[:format]
    when :jsonld, :json
      json = json_hash.to_json(JSON::LD::JSON_STATE)
      io.write(json) if io
      json
    when :turtle, :ttl
      if io
        earl_turtle(options)
      else
        io = StringIO.new
        earl_turtle(options.merge(io: io))
        io.rewind
        io.read
      end
    when :html
      template = case options[:template]
      when String then options[:tempate]
      when IO, StringIO then options[:template].read
      else
        File.read(File.expand_path('../earl_report/views/earl_report.html.haml', __FILE__))
      end

      # Generate HTML report
      html = Haml::Engine.new(template, format: :xhtml).render(self, tests: json_hash)
      io.write(html) if io
      html
    else
      writer = RDF::Writer.for(options[:format])
      writer.dump(@graph, io, options.merge(standard_prefixes: true))
    end
  end

  private
  
  ##
  # Return hashed EARL report in JSON-LD form
  # @return [Hash]
  def json_hash
    @json_hash ||= begin
      # Customized JSON-LD output
      r = JSON::LD::API.fromRDF(graph) do |expanded|
        JSON::LD::API.frame(expanded, TEST_FRAME, expanded: true, embed: '@never')
      end
      unless r.is_a?(Hash) && r.has_key?('@graph') && Array(r["@graph"]).length == 1
        raise "Expected JSON result to have a single entry, it had #{Array(r["@graph"]).length rescue 'unknown'} entries"
      end
      {"@context" => r["@context"]}.merge(r["@graph"].first)
    end
  end

  ##
  # Output consoloated EARL report as Turtle
  # @param [Hash{Symbol => Object}] options
  # @option options [IO, StringIO] :io
  # @return [String]
  def earl_turtle(options)
    io = options[:io]

    top_level = graph.first_subject(predicate: EARL.generatedBy)

    # Write starting with the entire graph to get preamble
    writer = RDF::Turtle::Writer.new(io, standard_prefixes: true)
    writer << graph

    writer.send(:preprocess)
    writer.send(:start_document)

    # Write top-level object referencing manifests and subjects
    writer.send(:statement, top_level)

    # Write each manifest
    io.puts "\n# Manifests"
    RDF::List.new(subject: graph.first_object(subject: top_level, predicate: MF[:entries]), graph: graph).each do |manifest|
      writer.send(:statement, manifest)

      # Write each test case
      RDF::List.new(subject: graph.first_object(subject: manifest, predicate: MF[:entries]), graph: graph).each do |tc|
        writer.send(:statement, tc)
      end
    end

    # Write test subjects
    io.puts "\n# Test Subjects"
    graph.query(subject: top_level, predicate: EARL.testSubjects).each do |s|
      writer.send(:statement, s.object)

      # Write each developer
      graph.query(subject: s.object, predicate: RDF::Vocab::DOAP.developer).each do |d|
        writer.send(:statement, d.object)
      end
    end

    # Write generator
    io.puts "\n# Report Generation Software"
    writer.send(:statement, RDF::URI("http://rubygems.org/gems/earl-report"))
    writer.send(:statement, RDF::URI("https://github.com/gkellogg/earl-report/tree/#{VERSION}"))
  end

  def quoted(string)
    (@turtle_writer ||= RDF::Turtle::Writer.new).send(:quoted, string)
  end

  def warn(message)
    $stderr.puts message
  end

  def status(message)
    $stderr.puts message if @options[:verbose]
  end
end
