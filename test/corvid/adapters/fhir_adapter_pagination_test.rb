# frozen_string_literal: true

require "minitest/autorun"
require "active_support/all"
require "json"
require "net/http"
require "corvid/adapters/fhir_adapter"

class Corvid::Adapters::FhirAdapterPaginationTest < Minitest::Test
  BASE_URL = "https://fhir.example.test/r4"

  def setup
    @adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE_URL)
  end

  # --- fhir_search: happy paths ------------------------------------------------

  def test_fhir_search_single_page_without_next_returns_bundle_unchanged_with_one_request
    entry = patient_entry("pt_page1_only")
    bundle = search_bundle(entries: [ entry ])
    initial_url = patient_search_url(name: "single")

    with_http_stub({ initial_url => success_json(bundle) }) do |requested|
      result = @adapter.send(:fhir_search, "Patient", name: "single")

      assert_equal [ entry ], result["entry"]
      assert_equal 1, requested.length
      assert_equal [ initial_url ], requested
    end
  end

  def test_fhir_search_three_absolute_same_origin_next_links_flattens_entries_in_order
    url1 = patient_search_url(name: "triple")
    url2 = "#{BASE_URL}/Patient?_getpages=page2&_getpagesoffset=10"
    url3 = "#{BASE_URL}/Patient?_getpages=page3&_getpagesoffset=20"

    e1 = patient_entry("pt_p1")
    e2 = patient_entry("pt_p2")
    e3 = patient_entry("pt_p3")

    responses = {
      url1 => success_json(search_bundle(entries: [ e1 ], next_url: url2)),
      url2 => success_json(search_bundle(entries: [ e2 ], next_url: url3)),
      url3 => success_json(search_bundle(entries: [ e3 ]))
    }

    with_http_stub(responses) do |requested|
      result = @adapter.send(:fhir_search, "Patient", name: "triple")

      assert_equal [ e1, e2, e3 ], result["entry"]
      assert_equal [ url1, url2, url3 ], requested
    end
  end

  def test_fhir_search_follows_relative_same_origin_next_link_resolved_against_current_page
    url1 = patient_search_url(name: "relative")
    url2 = "#{BASE_URL}/Patient?page=2&name=relative"

    e1 = patient_entry("pt_rel_1")
    e2 = patient_entry("pt_rel_2")

    responses = {
      url1 => success_json(search_bundle(entries: [ e1 ], next_url: "Patient?page=2&name=relative")),
      url2 => success_json(search_bundle(entries: [ e2 ]))
    }

    with_http_stub(responses) do |requested|
      result = @adapter.send(:fhir_search, "Patient", name: "relative")

      assert_equal [ e1, e2 ], result["entry"]
      assert_equal [ url1, url2 ], requested
    end
  end

  def test_fhir_search_follows_root_relative_next_link_under_base_path
    url1 = patient_search_url(name: "rootrel")
    url2 = "#{BASE_URL}/Patient?_getpages=abc"

    e1 = patient_entry("pt_rr_1")
    e2 = patient_entry("pt_rr_2")

    responses = {
      url1 => success_json(search_bundle(entries: [ e1 ], next_url: "/r4/Patient?_getpages=abc")),
      url2 => success_json(search_bundle(entries: [ e2 ]))
    }

    with_http_stub(responses) do |requested|
      result = @adapter.send(:fhir_search, "Patient", name: "rootrel")

      assert_equal [ e1, e2 ], result["entry"]
      assert_equal [ url1, url2 ], requested
    end
  end

  def test_list_claims_aggregates_claim_lines_across_paginated_search
    patient_id = "pt_claims_pages"
    url1 = "#{BASE_URL}/Claim?patient=#{patient_id}"
    url2 = "#{BASE_URL}/Claim?_getpages=claims2"

    claim1 = claim_resource("clm_1", patient_id, sequence: 1)
    claim2 = claim_resource("clm_2", patient_id, sequence: 2)

    responses = {
      url1 => success_json(search_bundle(
        entries: [ { "resource" => claim1 } ],
        next_url: url2
      )),
      url2 => success_json(search_bundle(entries: [ { "resource" => claim2 } ]))
    }

    with_http_stub(responses) do |requested|
      lines = @adapter.list_claims(patient_id)
      claim_ids = lines.map(&:claim_identifier).sort

      assert_equal %w[clm_1 clm_2], claim_ids
      assert_equal [ url1, url2 ], requested
    end
  end

  # --- fhir_search: fail closed on later pages ---------------------------------

  def test_fhir_search_returns_nil_when_page_two_is_non_success
    url1 = patient_search_url(name: "p2fail")
    url2 = "#{BASE_URL}/Patient?_getpages=p2fail"

    responses = {
      url1 => success_json(search_bundle(entries: [ patient_entry("pt_a") ], next_url: url2)),
      url2 => http_error(502, "bad gateway")
    }

    with_http_stub(responses) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "p2fail")
      assert_equal [ url1, url2 ], requested
    end
  end

  def test_fhir_search_returns_nil_when_page_two_body_is_invalid_json
    url1 = patient_search_url(name: "p2json")
    url2 = "#{BASE_URL}/Patient?_getpages=p2json"

    responses = {
      url1 => success_json(search_bundle(entries: [ patient_entry("pt_b") ], next_url: url2)),
      url2 => success_raw("{not-json")
    }

    with_http_stub(responses) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "p2json")
      assert_equal [ url1, url2 ], requested
    end
  end

  def test_fhir_search_returns_nil_when_page_two_body_is_not_a_bundle
    url1 = patient_search_url(name: "p2oo")
    url2 = "#{BASE_URL}/Patient?_getpages=p2oo"

    outcome = {
      "resourceType" => "OperationOutcome",
      "issue" => [ { "severity" => "error", "code" => "processing" } ]
    }

    responses = {
      url1 => success_json(search_bundle(entries: [ patient_entry("pt_c") ], next_url: url2)),
      url2 => success_json(outcome)
    }

    with_http_stub(responses) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "p2oo")
      assert_equal [ url1, url2 ], requested
    end
  end

  # --- fhir_search: same origin enforcement ------------------------------------

  def test_fhir_search_returns_nil_for_cross_origin_next_host_without_requesting_it
    evil_next = "https://evil.example.test/r4/Patient?page=2"
    url1 = patient_search_url(name: "xhost")

    with_http_stub({
      url1 => success_json(search_bundle(entries: [ patient_entry("pt_xh") ], next_url: evil_next))
    }) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "xhost")
      refute_includes requested, evil_next
      assert_equal [ url1 ], requested
    end
  end

  def test_fhir_search_returns_nil_for_cross_origin_next_scheme_without_requesting_it
    evil_next = "http://fhir.example.test/r4/Patient?page=2"
    url1 = patient_search_url(name: "xscheme")

    with_http_stub({
      url1 => success_json(search_bundle(entries: [ patient_entry("pt_xs") ], next_url: evil_next))
    }) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "xscheme")
      refute_includes requested, evil_next
      assert_equal [ url1 ], requested
    end
  end

  def test_fhir_search_returns_nil_for_cross_origin_next_port_without_requesting_it
    evil_next = "https://fhir.example.test:8443/r4/Patient?page=2"
    url1 = patient_search_url(name: "xport")

    with_http_stub({
      url1 => success_json(search_bundle(entries: [ patient_entry("pt_xp") ], next_url: evil_next))
    }) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "xport")
      refute_includes requested, evil_next
      assert_equal [ url1 ], requested
    end
  end

  # --- fhir_search: loop safety ------------------------------------------------

  def test_fhir_search_returns_nil_when_next_link_revisits_first_page_url
    url1 = patient_search_url(name: "loopback")
    url2 = "#{BASE_URL}/Patient?_getpages=loop2"

    responses = {
      url1 => success_json(search_bundle(entries: [ patient_entry("pt_l1") ], next_url: url2)),
      url2 => success_json(search_bundle(entries: [ patient_entry("pt_l2") ], next_url: url1))
    }

    with_http_stub(responses) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "loopback")
      assert_equal [ url1, url2 ], requested
    end
  end

  def test_fhir_search_returns_nil_when_next_link_points_to_same_page_url
    url1 = patient_search_url(name: "selfloop")

    with_http_stub({
      url1 => success_json(search_bundle(entries: [ patient_entry("pt_sl") ], next_url: url1))
    }) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "selfloop")
      assert_equal [ url1 ], requested
    end
  end

  def test_fhir_search_returns_nil_when_page_cap_exceeded
    cap = Corvid::Adapters::FhirAdapter::MAX_SEARCH_PAGES
    responses = {}
    urls = []

    cap.times do |i|
      urls << (i.zero? ? patient_search_url(name: "endless") : "#{BASE_URL}/Patient?_getpages=e#{i}")
    end
    urls << "#{BASE_URL}/Patient?_getpages=e#{cap}"

    urls.each_with_index do |url, i|
      next_url = urls[i + 1]
      entry = patient_entry("pt_e#{i}")
      body = next_url ? search_bundle(entries: [ entry ], next_url: next_url) : search_bundle(entries: [ entry ])
      responses[url] = success_json(body)
    end

    with_http_stub(responses) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "endless")
      assert_operator requested.length, :<=, cap
    end
  end

  # --- fhir_search: first page failures (existing contract) ------------------

  def test_fhir_search_returns_nil_when_first_page_is_non_success
    url1 = patient_search_url(name: "firstfail")

    with_http_stub({ url1 => http_error(404, "not found") }) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "firstfail")
      assert_equal [ url1 ], requested
    end
  end

  def test_fhir_search_returns_nil_when_first_page_body_is_invalid_json
    url1 = patient_search_url(name: "firstjson")

    with_http_stub({ url1 => success_raw("<<broken>>") }) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "firstjson")
      assert_equal [ url1 ], requested
    end
  end

  # --- fhir_search: link relation filtering ------------------------------------

  def test_fhir_search_does_not_follow_non_next_link_relations
    url1 = patient_search_url(name: "selfonly")
    self_url = url1
    prev_url = "#{BASE_URL}/Patient?page=0&name=selfonly"
    entry = patient_entry("pt_sn")

    bundle = search_bundle(entries: [ entry ])
    bundle["link"] = [
      { "relation" => "self", "url" => self_url },
      { "relation" => "previous", "url" => prev_url }
    ]

    with_http_stub({ url1 => success_json(bundle) }) do |requested|
      result = @adapter.send(:fhir_search, "Patient", name: "selfonly")

      assert_equal [ entry ], result["entry"]
      assert_equal [ url1 ], requested
    end
  end

  # --- fhir_search: entry shape (gate round 1) ---------------------------------

  def test_fhir_search_returns_nil_when_page_entry_is_a_hash
    url1 = patient_search_url(name: "entryhash")
    url2 = "#{BASE_URL}/Patient?_getpages=entryhash2"

    responses = {
      url1 => success_json(search_bundle(entries: [ patient_entry("pt_eh1") ], next_url: url2)),
      url2 => success_json(search_bundle(entries: { "resource" => { "resourceType" => "Patient", "id" => "bad" } }))
    }

    with_http_stub(responses) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "entryhash")
      assert_equal [ url1, url2 ], requested
    end
  end

  def test_fhir_search_returns_nil_when_page_entry_is_a_string
    url1 = patient_search_url(name: "entrystr")

    with_http_stub({
      url1 => success_json(search_bundle(entries: "not-an-array"))
    }) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "entrystr")
      assert_equal [ url1 ], requested
    end
  end

  def test_fhir_search_treats_missing_or_null_entry_as_empty_page_and_continues_chain
    url1 = patient_search_url(name: "entrygap")
    url2 = "#{BASE_URL}/Patient?_getpages=entrygap2"
    url3 = "#{BASE_URL}/Patient?_getpages=entrygap3"

    e1 = patient_entry("pt_gap1")
    e3 = patient_entry("pt_gap3")

    page2_no_entry = search_bundle(entries: :omit, next_url: url3)
    page2_null_entry = search_bundle(entries: nil, next_url: url3)

    responses = {
      url1 => success_json(search_bundle(entries: [ e1 ], next_url: url2)),
      url2 => success_json(page2_no_entry),
      url3 => success_json(search_bundle(entries: [ e3 ]))
    }

    with_http_stub(responses) do |requested|
      result = @adapter.send(:fhir_search, "Patient", name: "entrygap")

      assert_equal [ e1, e3 ], result["entry"]
      assert_equal [ url1, url2, url3 ], requested
    end

    responses[url2] = success_json(page2_null_entry)

    with_http_stub(responses) do |requested|
      result = @adapter.send(:fhir_search, "Patient", name: "entrygap")

      assert_equal [ e1, e3 ], result["entry"]
      assert_equal [ url1, url2, url3 ], requested
    end
  end

  # --- fhir_search: link shape and relation (gate round 1) ---------------------

  def test_fhir_search_returns_nil_when_link_is_present_but_not_an_array
    url1 = patient_search_url(name: "linkhash")
    evil_next = "#{BASE_URL}/Patient?page=2&name=linkhash"

    bundle = search_bundle(entries: [ patient_entry("pt_lh") ])
    bundle["link"] = { "relation" => "next", "url" => evil_next }

    with_http_stub({ url1 => success_json(bundle) }) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "linkhash")
      refute_includes requested, evil_next
      assert_equal [ url1 ], requested
    end
  end

  def test_fhir_search_returns_nil_for_case_insensitive_next_relation_without_requesting_url
    [
      [ "Next", "casing_next" ],
      [ "NEXT", "casing_next_upper" ],
      [ " next", "casing_next_space" ]
    ].each do |relation, name|
      url1 = patient_search_url(name: name)
      evil_next = "#{BASE_URL}/Patient?page=2&name=#{name}"

      bundle = search_bundle(entries: [ patient_entry("pt_rel") ])
      bundle["link"] = [ { "relation" => relation, "url" => evil_next } ]

      with_http_stub({ url1 => success_json(bundle) }) do |requested|
        assert_nil @adapter.send(:fhir_search, "Patient", name: name),
          "expected nil for relation #{relation.inspect}"
        refute_includes requested, evil_next
        assert_equal [ url1 ], requested
      end
    end
  end

  def test_fhir_search_returns_nil_when_bundle_has_two_next_links_without_requesting_either
    url1 = patient_search_url(name: "twonext")
    next_a = "#{BASE_URL}/Patient?_getpages=twonext_a"
    next_b = "#{BASE_URL}/Patient?_getpages=twonext_b"

    bundle = search_bundle(entries: [ patient_entry("pt_2n") ], links: [
      { "relation" => "next", "url" => next_a },
      { "relation" => "next", "url" => next_b }
    ])

    responses = {
      url1 => success_json(bundle),
      next_a => success_json(search_bundle(entries: [ patient_entry("pt_2n_a") ])),
      next_b => success_json(search_bundle(entries: [ patient_entry("pt_2n_b") ]))
    }

    with_http_stub(responses) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "twonext")
      refute_includes requested, next_a
      refute_includes requested, next_b
      assert_equal [ url1 ], requested
    end
  end

  # --- fhir_search: merged total (gate round 1) --------------------------------

  def test_fhir_search_returns_nil_when_first_page_total_differs_from_merged_entry_count
    url1 = patient_search_url(name: "totalbad")
    url2 = "#{BASE_URL}/Patient?_getpages=totalbad2"

    e1 = patient_entry("pt_tb1")
    e2 = patient_entry("pt_tb2")

    responses = {
      url1 => success_json(search_bundle(entries: [ e1 ], next_url: url2, total: 99)),
      url2 => success_json(search_bundle(entries: [ e2 ]))
    }

    with_http_stub(responses) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "totalbad")
      assert_equal [ url1, url2 ], requested
    end
  end

  def test_fhir_search_keeps_total_when_first_page_total_matches_merged_entry_count
    url1 = patient_search_url(name: "totalok")
    url2 = "#{BASE_URL}/Patient?_getpages=totalok2"

    e1 = patient_entry("pt_to1")
    e2 = patient_entry("pt_to2")

    responses = {
      url1 => success_json(search_bundle(entries: [ e1 ], next_url: url2, total: 2)),
      url2 => success_json(search_bundle(entries: [ e2 ]))
    }

    with_http_stub(responses) do |requested|
      result = @adapter.send(:fhir_search, "Patient", name: "totalok")

      assert_equal [ e1, e2 ], result["entry"]
      assert_equal 2, result["total"]
      assert_equal [ url1, url2 ], requested
    end
  end

  def test_fhir_search_omits_total_in_merged_bundle_when_first_page_has_no_total
    url1 = patient_search_url(name: "nototal")
    url2 = "#{BASE_URL}/Patient?_getpages=nototal2"

    e1 = patient_entry("pt_nt1")
    e2 = patient_entry("pt_nt2")

    responses = {
      url1 => success_json(search_bundle(entries: [ e1 ], next_url: url2)),
      url2 => success_json(search_bundle(entries: [ e2 ]))
    }

    with_http_stub(responses) do |requested|
      result = @adapter.send(:fhir_search, "Patient", name: "nototal")

      assert_equal [ e1, e2 ], result["entry"]
      refute result.key?("total")
      assert_equal [ url1, url2 ], requested
    end
  end

  # --- fhir_search: base path prefix (gate round 1) ----------------------------

  def test_fhir_search_returns_nil_for_same_origin_next_outside_base_path_without_requesting
    tenant_base = "https://fhir.example.test/tenant-a/r4"
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: tenant_base)
    url1 = "#{tenant_base}/Patient?#{URI.encode_www_form(name: "tenantpath")}"
    outside_next = "/tenant-b/r4/Patient?page=2"
    resolved_outside = "https://fhir.example.test#{outside_next}"
    responses = {
      url1 => success_json(search_bundle(entries: [ patient_entry("pt_tp") ], next_url: outside_next)),
      resolved_outside => success_json(search_bundle(entries: [ patient_entry("pt_tp_out") ]))
    }

    requested = []
    handler = lambda do |url|
      requested << url
      response = responses[url]
      raise "unexpected http_get: #{url}" unless response

      response
    end

    adapter.stub(:http_get, handler) do
      assert_nil adapter.send(:fhir_search, "Patient", name: "tenantpath")
    end

    refute_includes requested, resolved_outside
    assert_equal [ url1 ], requested
  end

  def test_fhir_search_follows_same_origin_next_inside_base_path_prefix
    tenant_base = "https://fhir.example.test/tenant-a/r4"
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: tenant_base)
    url1 = "#{tenant_base}/Patient?#{URI.encode_www_form(name: "tenantin")}"
    url2 = "#{tenant_base}/Patient?page=2&name=tenantin"

    e1 = patient_entry("pt_ti1")
    e2 = patient_entry("pt_ti2")

    responses = {
      url1 => success_json(search_bundle(entries: [ e1 ], next_url: "Patient?page=2&name=tenantin")),
      url2 => success_json(search_bundle(entries: [ e2 ]))
    }

    requested = []
    handler = lambda do |url|
      requested << url
      responses[url] || raise("unexpected http_get: #{url}")
    end

    adapter.stub(:http_get, handler) do
      result = adapter.send(:fhir_search, "Patient", name: "tenantin")

      assert_equal [ e1, e2 ], result["entry"]
      assert_equal [ url1, url2 ], requested
    end
  end

  # --- fhir_search: page cap success (gate round 1) ----------------------------

  def test_fhir_search_succeeds_with_exactly_max_search_pages_and_no_trailing_next
    cap = Corvid::Adapters::FhirAdapter::MAX_SEARCH_PAGES
    responses = {}
    urls = []
    expected_entries = []

    cap.times do |i|
      urls << (i.zero? ? patient_search_url(name: "maxok") : "#{BASE_URL}/Patient?_getpages=maxok#{i}")
    end

    urls.each_with_index do |url, i|
      entry = patient_entry("pt_maxok#{i}")
      expected_entries << entry
      next_url = i < cap - 1 ? urls[i + 1] : nil
      responses[url] = success_json(search_bundle(entries: [ entry ], next_url: next_url))
    end

    with_http_stub(responses) do |requested|
      result = @adapter.send(:fhir_search, "Patient", name: "maxok")

      assert_equal expected_entries, result["entry"]
      assert_equal urls, requested
      assert_equal cap, requested.length
    end
  end

  private

  def patient_search_url(name:)
    "#{BASE_URL}/Patient?#{URI.encode_www_form(name: name)}"
  end

  def search_bundle(entries:, next_url: nil, link_relation: "next", total: :__unset__, links: nil)
    bundle = {
      "resourceType" => "Bundle",
      "type" => "searchset"
    }
    bundle["total"] = total unless total == :__unset__
    bundle["entry"] = entries unless entries == :omit
    bundle["link"] = if links
      links
    elsif next_url
      [ { "relation" => link_relation, "url" => next_url } ]
    else
      []
    end
    bundle
  end

  def patient_entry(id)
    {
      "resource" => {
        "resourceType" => "Patient",
        "id" => id,
        "birthDate" => "1980-01-01",
        "gender" => "female",
        "name" => [ { "family" => "TEST", "given" => [ "PATIENT#{id}" ] } ]
      }
    }
  end

  def claim_resource(claim_id, patient_id, sequence:)
    {
      "resourceType" => "Claim",
      "id" => claim_id,
      "patient" => { "reference" => "Patient/#{patient_id}" },
      "item" => [ {
        "sequence" => sequence,
        "productOrService" => {
          "coding" => [ { "system" => "http://www.ama-assn.org/go/cpt", "code" => "99213" } ]
        },
        "net" => { "value" => 100.0, "currency" => "USD" }
      } ]
    }
  end

  def with_http_stub(responses_by_url)
    requested = []
    handler = lambda do |url|
      requested << url
      response = responses_by_url[url]
      raise "unexpected http_get: #{url}" unless response

      response
    end

    @adapter.stub(:http_get, handler) { yield requested }
  end

  def success_json(payload)
    success_raw(JSON.generate(payload))
  end

  def success_raw(body)
    fake_response(200, body)
  end

  def http_error(status, body)
    fake_response(status, body)
  end

  def fake_response(status, body)
    response_class = if status >= 200 && status < 300
      Net::HTTPOK
    else
      Net::HTTPResponse::CODE_TO_OBJ[status.to_s] || Net::HTTPUnknownResponse
    end
    response = response_class.new("1.1", status.to_s, "OK")
    response.instance_variable_set(:@body, body)
    response.instance_variable_set(:@read, true)
    response
  end
end
