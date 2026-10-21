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

  # --- fhir_search: total vs search.mode (gate round 2) ----------------------

  def test_fhir_search_keeps_total_when_outcome_entry_does_not_count_toward_total
    url1 = patient_search_url(name: "totalmode1")
    match = patient_entry("p1", search_mode: "match")
    outcome = operation_outcome_entry(search_mode: "outcome")
    bundle = search_bundle(entries: [ match, outcome ], total: 1)

    with_http_stub({ url1 => success_json(bundle) }) do |requested|
      result = @adapter.send(:fhir_search, "Patient", name: "totalmode1")

      assert_equal [ match, outcome ], result["entry"]
      assert_equal 1, result["total"]
      assert_equal [ url1 ], requested
    end
  end

  def test_search_patients_succeeds_when_total_counts_only_match_entries
    url1 = patient_search_url(name: "totalmode_sp")
    match = patient_entry("p1", search_mode: "match")
    outcome = operation_outcome_entry(search_mode: "outcome")
    bundle = search_bundle(entries: [ match, outcome ], total: 1)

    with_http_stub({ url1 => success_json(bundle) }) do |_requested|
      refs = @adapter.search_patients("totalmode_sp")

      assert_equal 1, refs.length
      assert_equal "p1", refs.first.identifier
    end
  end

  def test_fhir_search_keeps_total_when_include_entry_does_not_count_toward_total
    url1 = patient_search_url(name: "totalinc")
    match = patient_entry("p_main", search_mode: "match")
    included = patient_entry("p_inc", search_mode: "include")
    bundle = search_bundle(entries: [ match, included ], total: 1)

    with_http_stub({ url1 => success_json(bundle) }) do |requested|
      result = @adapter.send(:fhir_search, "Patient", name: "totalinc")

      assert_equal [ match, included ], result["entry"]
      assert_equal 1, result["total"]
      assert_equal [ url1 ], requested
    end
  end

  def test_fhir_search_keeps_total_zero_when_only_outcome_entry_present
    url1 = patient_search_url(name: "totalout0")
    outcome = operation_outcome_entry(search_mode: "outcome")
    bundle = search_bundle(entries: [ outcome ], total: 0)

    with_http_stub({ url1 => success_json(bundle) }) do |requested|
      result = @adapter.send(:fhir_search, "Patient", name: "totalout0")

      assert_equal [ outcome ], result["entry"]
      assert_equal 0, result["total"]
      assert_equal [ url1 ], requested
    end
  end

  def test_fhir_search_returns_nil_when_total_disagrees_with_match_and_no_mode_count
    url1 = patient_search_url(name: "totalmm")
    entries = [
      patient_entry("p_a", search_mode: "match"),
      patient_entry("p_b"),
      operation_outcome_entry(search_mode: "outcome")
    ]
    bundle = search_bundle(entries: entries, total: 1)

    with_http_stub({ url1 => success_json(bundle) }) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "totalmm")
      assert_equal [ url1 ], requested
    end
  end

  def test_fhir_search_returns_nil_when_total_is_float
    url1 = patient_search_url(name: "totalfloat")
    bundle = search_bundle(entries: [ patient_entry("p_f") ], total: 3.0)

    with_http_stub({ url1 => success_json(bundle) }) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "totalfloat")
      assert_equal [ url1 ], requested
    end
  end

  def test_fhir_search_returns_nil_when_total_is_string
    url1 = patient_search_url(name: "totalstr")
    bundle = search_bundle(entries: [ patient_entry("p_s") ], total: "3")

    with_http_stub({ url1 => success_json(bundle) }) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "totalstr")
      assert_equal [ url1 ], requested
    end
  end

  def test_fhir_search_returns_nil_when_total_is_negative_integer
    url1 = patient_search_url(name: "totalneg")
    bundle = search_bundle(entries: [ patient_entry("p_n") ], total: -1)

    with_http_stub({ url1 => success_json(bundle) }) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "totalneg")
      assert_equal [ url1 ], requested
    end
  end

  # --- fhir_search: duplicate match resources (gate round 2) -----------------

  def test_fhir_search_returns_nil_when_same_match_patient_appears_twice_on_one_page
    url1 = patient_search_url(name: "dup1page")
    e1 = patient_entry("p_dup", search_mode: "match")
    e2 = patient_entry("p_dup", search_mode: "match")
    bundle = search_bundle(entries: [ e1, e2 ], total: 2)

    with_http_stub({ url1 => success_json(bundle) }) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "dup1page")
      assert_equal [ url1 ], requested
    end
  end

  def test_fhir_search_returns_nil_when_same_no_mode_patient_appears_on_later_page
    url1 = patient_search_url(name: "dup2page")
    url2 = "#{BASE_URL}/Patient?_getpages=dup2&name=dup2page"

    e1 = patient_entry("p_x")
    e2 = patient_entry("p_x")

    responses = {
      url1 => success_json(search_bundle(entries: [ e1 ], next_url: url2, total: 2)),
      url2 => success_json(search_bundle(entries: [ e2 ]))
    }

    with_http_stub(responses) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "dup2page")
      assert_equal [ url1, url2 ], requested
    end
  end

  def test_fhir_search_returns_nil_when_same_match_patient_reappears_via_next_link_with_reordered_params
    url1 = patient_search_url(name: "dupreorder")
    url2 = "#{BASE_URL}/Patient?name=dupreorder&_getpages=dupre"

    e1 = patient_entry("p_ro", search_mode: "match")
    e2 = patient_entry("p_ro", search_mode: "match")

    responses = {
      url1 => success_json(search_bundle(entries: [ e1 ], next_url: url2, total: 2)),
      url2 => success_json(search_bundle(entries: [ e2 ]))
    }

    with_http_stub(responses) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "dupreorder")
      assert_equal [ url1, url2 ], requested
    end
  end

  def test_fhir_search_returns_nil_when_same_match_patient_reappears_via_next_link_with_trailing_slash
    url1 = patient_search_url(name: "dupslash")
    url2 = "#{BASE_URL}/Patient/?_getpages=dupslash2&name=dupslash"

    e1 = patient_entry("p_sl", search_mode: "match")
    e2 = patient_entry("p_sl", search_mode: "match")

    responses = {
      url1 => success_json(search_bundle(entries: [ e1 ], next_url: url2, total: 2)),
      url2 => success_json(search_bundle(entries: [ e2 ]))
    }

    with_http_stub(responses) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "dupslash")
      assert_equal [ url1, url2 ], requested
    end
  end

  def test_fhir_search_allows_same_include_patient_on_later_page
    url1 = patient_search_url(name: "dupincok")
    url2 = "#{BASE_URL}/Patient?_getpages=dupinc2"

    match = patient_entry("p_m", search_mode: "match")
    inc1 = patient_entry("p_i", search_mode: "include")
    inc2 = patient_entry("p_i", search_mode: "include")

    responses = {
      url1 => success_json(search_bundle(entries: [ match, inc1 ], next_url: url2)),
      url2 => success_json(search_bundle(entries: [ inc2 ]))
    }

    with_http_stub(responses) do |requested|
      result = @adapter.send(:fhir_search, "Patient", name: "dupincok")

      assert_equal [ match, inc1, inc2 ], result["entry"]
      refute result.key?("total")
      assert_equal [ url1, url2 ], requested
    end
  end

  # --- fhir_search: dot segments in next URL (gate round 2) ------------------

  def test_fhir_search_returns_nil_for_next_url_with_raw_dot_dot_segment_without_requesting
    evil_next = "#{BASE_URL}/../admin/Patient?page=2"
    url1 = patient_search_url(name: "dotdot")

    with_http_stub({
      url1 => success_json(search_bundle(entries: [ patient_entry("pt_dd") ], next_url: evil_next)),
      evil_next => success_json(search_bundle(entries: [ patient_entry("pt_dd2") ]))
    }) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "dotdot")
      refute_includes requested, evil_next
      assert_equal [ url1 ], requested
    end
  end

  def test_fhir_search_returns_nil_for_next_url_with_raw_dot_segment_without_requesting
    evil_next = "#{BASE_URL}/./Patient?page=2"
    url1 = patient_search_url(name: "dotseg")

    with_http_stub({
      url1 => success_json(search_bundle(entries: [ patient_entry("pt_ds") ], next_url: evil_next)),
      evil_next => success_json(search_bundle(entries: [ patient_entry("pt_ds2") ]))
    }) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "dotseg")
      refute_includes requested, evil_next
      assert_equal [ url1 ], requested
    end
  end

  def test_fhir_search_returns_nil_for_next_url_with_percent_encoded_dot_dot_without_requesting
    evil_next = "https://fhir.example.test/r4/%2e%2e/admin/Patient?page=2"
    url1 = patient_search_url(name: "dotenc")

    with_http_stub({
      url1 => success_json(search_bundle(entries: [ patient_entry("pt_de") ], next_url: evil_next)),
      evil_next => success_json(search_bundle(entries: [ patient_entry("pt_de2") ]))
    }) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "dotenc")
      refute_includes requested, evil_next
      assert_equal [ url1 ], requested
    end
  end

  def test_fhir_search_returns_nil_for_next_url_with_percent_encoded_dot_uppercase_without_requesting
    evil_next = "https://fhir.example.test/r4/%2E%2E/admin/Patient?page=2"
    url1 = patient_search_url(name: "dotencu")

    with_http_stub({
      url1 => success_json(search_bundle(entries: [ patient_entry("pt_deu") ], next_url: evil_next)),
      evil_next => success_json(search_bundle(entries: [ patient_entry("pt_deu2") ]))
    }) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "dotencu")
      refute_includes requested, evil_next
      assert_equal [ url1 ], requested
    end
  end

  # --- fhir_search: empty later page body (gate round 2) ---------------------

  def test_fhir_search_returns_nil_when_page_two_is_204_no_content_without_raise
    url1 = patient_search_url(name: "p2empty")
    url2 = "#{BASE_URL}/Patient?_getpages=p2empty"

    responses = {
      url1 => success_json(search_bundle(entries: [ patient_entry("pt_p2e") ], next_url: url2)),
      url2 => success_no_content
    }

    with_http_stub(responses) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "p2empty")
      assert_equal [ url1, url2 ], requested
    end
  end

  def test_fhir_search_returns_nil_when_page_two_is_200_with_empty_body_without_raise
    url1 = patient_search_url(name: "p2blank")
    url2 = "#{BASE_URL}/Patient?_getpages=p2blank"

    responses = {
      url1 => success_json(search_bundle(entries: [ patient_entry("pt_p2b") ], next_url: url2)),
      url2 => success_raw("")
    }

    with_http_stub(responses) do |requested|
      assert_nil @adapter.send(:fhir_search, "Patient", name: "p2blank")
      assert_equal [ url1, url2 ], requested
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

  def patient_entry(id, search_mode: nil)
    entry = {
      "resource" => {
        "resourceType" => "Patient",
        "id" => id,
        "birthDate" => "1980-01-01",
        "gender" => "female",
        "name" => [ { "family" => "TEST", "given" => [ "PATIENT#{id}" ] } ]
      }
    }
    entry["search"] = { "mode" => search_mode } if search_mode
    entry
  end

  def operation_outcome_entry(search_mode: "outcome")
    {
      "search" => { "mode" => search_mode },
      "resource" => {
        "resourceType" => "OperationOutcome",
        "issue" => [ { "severity" => "information", "code" => "informational" } ]
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

  def success_no_content
    fake_response(204, nil)
  end

  def http_error(status, body)
    fake_response(status, body)
  end

  def fake_response(status, body)
    response_class = Net::HTTPResponse::CODE_TO_OBJ[status.to_s]
    response_class ||= status.between?(200, 299) ? Net::HTTPOK : Net::HTTPUnknownResponse
    response = response_class.new("1.1", status.to_s, "OK")
    response.instance_variable_set(:@body, body)
    response.instance_variable_set(:@read, true)
    response
  end
end
