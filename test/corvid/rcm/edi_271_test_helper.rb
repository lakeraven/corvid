# frozen_string_literal: true

# Builds synthetic X12 271 strings for eligibility tests. SE01 counts ST through
# SE inclusive.
module Corvid::Rcm::Edi271TestHelper
  module_function

  FIXED_CLOCK = -> { Time.utc(2026, 9, 1, 12, 0, 0) }

  DEFAULT_ISA = File.read(
    File.expand_path("../../../lib/corvid/rcm/fixtures/271/MBR-ACTIVE-COMMERCIAL.271", __dir__)
  )[0, 106].freeze

  PIPE_ISA = "ISA|00|          |00|          |ZZ|EXAMPLECLRHOUSE|ZZ|EXAMPLECLINIC  |260901|1200|+|00501|000000101|0|T|:\n".freeze

  # ISA repetition separator "|" (element still "*"); EB03 repeats with "|".
  REP_PIPE_ISA = DEFAULT_ISA.sub("*^*", "*|*").freeze

  def delimiters(profile)
    case profile
    when :pipes
      { segment: "\n", element: "|", repetition: "+", component: ":", isa: PIPE_ISA }
    when :rep_pipe
      { segment: "~", element: "*", repetition: "|", component: ">", isa: REP_PIPE_ISA }
    else
      { segment: "~", element: "*", repetition: "^", component: ">", isa: DEFAULT_ISA }
    end
  end

  def join_segments(segments, profile: :default)
    d = delimiters(profile)
    segments.map { |segment| "#{segment}#{d.fetch(:segment)}" }.join
  end

  def build_271(member_token:, body_after_subscriber: [], st_control: "9001", profile: :default,
                subscriber_hl_has_child: false, payer_identifier: "EXPAYER01",
                payer_name: "EXAMPLE COMMERCIAL PAYER", include_trailer: true,
                payer_id_qualifier: "PI", isa_override: nil)
    d = delimiters(profile)
    rep = d.fetch(:repetition)
    el = d.fetch(:element)

    subscriber_trailer = subscriber_hl_has_child ? "1" : "0"
    txn = [
      join_fields(%w[ST 271], st_control, "005010X279A1", profile: profile),
      join_fields(%w[BHT 0022 11], st_control, "20260901", "1200", profile: profile),
      join_fields(%w[HL 1], "", "20", "1", profile: profile),
      join_fields(
        [ "NM1", "PR", "2", payer_name, "", "", "", "", payer_id_qualifier, payer_identifier ],
        profile: profile
      ),
      join_fields(%w[HL 2 1 21 1], profile: profile),
      join_fields(
        [ "NM1", "1P", "2", "EXAMPLE BEHAVIORAL HEALTH CLINIC", "", "", "", "", "XX", "1999999992" ],
        profile: profile
      ),
      join_fields([ "HL", "3", "2", "22", subscriber_trailer ], profile: profile),
      join_fields([ "NM1", "IL", "1", "", "", "", "", "", "", "MI", member_token ], profile: profile),
      *body_after_subscriber.map { |segment| translate_segment(segment, profile: profile, rep: rep, el: el) }
    ]

    if include_trailer
      se_count = txn.length + 1
      txn << join_fields([ "SE", se_count.to_s, st_control ], profile: profile)
    end

    isa_segment = isa_override || d.fetch(:isa)
    envelope = [
      isa_segment.chomp(d.fetch(:segment)),
      join_fields(
        %w[GS HB EXAMPLECLRHOUSE EXAMPLECLINIC 20260901 1200 101 X 005010X279A1],
        profile: profile
      ),
      *txn,
      join_fields(%w[GE 1 101], profile: profile),
      join_fields(%w[IEA 1 000000101], profile: profile)
    ]

    join_segments(envelope, profile: profile)
  end

  # Two HL level-20 (information source) loops — ambiguous payer/plan context (#736 review-3).
  def build_271_two_information_sources(member_token:, body_after_subscriber:, st_control: "9501",
                                        first_payer: "EXPAYER01", second_payer: "OTHERPAYER")
    d = delimiters(:default)
    txn = [
      join_fields(%w[ST 271], st_control, "005010X279A1"),
      join_fields(%w[BHT 0022 11], st_control, "20260901", "1200"),
      join_fields(%w[HL 1], "", "20", "0"),
      join_fields([ "NM1", "PR", "2", "EXAMPLE PAYER A", "", "", "", "", "PI", first_payer ]),
      join_fields(%w[HL 2], "", "20", "1"),
      join_fields([ "NM1", "PR", "2", "EXAMPLE PAYER B", "", "", "", "", "PI", second_payer ]),
      join_fields(%w[HL 3 2 21 1]),
      join_fields([ "NM1", "1P", "2", "EXAMPLE BEHAVIORAL HEALTH CLINIC", "", "", "", "", "XX", "1999999992" ]),
      join_fields(%w[HL 4 3 22 0]),
      join_fields([ "NM1", "IL", "1", "", "", "", "", "", "", "MI", member_token ]),
      *body_after_subscriber
    ]
    se_count = txn.length + 1
    txn << join_fields([ "SE", se_count.to_s, st_control ])
    envelope = [
      d.fetch(:isa).chomp(d.fetch(:segment)),
      join_fields(%w[GS HB EXAMPLECLRHOUSE EXAMPLECLINIC 20260901 1200 101 X 005010X279A1]),
      *txn,
      join_fields(%w[GE 1 101]),
      join_fields(%w[IEA 1 000000101])
    ]
    join_segments(envelope)
  end

  # ISA element and repetition separators both "|" — malformed interchange (#736 review-3).
  def build_271_duplicate_isa_separators(member_token:, body_after_subscriber: [ "EB*1*IND*30" ])
    bad_isa = DEFAULT_ISA.sub("*^*", "*|*").sub("*T*>~", "*T*|~")
    build_271(
      member_token: member_token,
      body_after_subscriber: body_after_subscriber,
      isa_override: bad_isa
    )
  end

  def build_271_with_second_transaction(member_token:, first_body:, second_body:, st_control: "9001")
    d = delimiters(:default)
    first_txn = transaction_segments(
      member_token: member_token,
      body_after_subscriber: first_body,
      st_control: "#{st_control}A"
    )
    second_txn = transaction_segments(
      member_token: member_token,
      body_after_subscriber: second_body,
      st_control: "#{st_control}B"
    )
    envelope = [
      d.fetch(:isa).chomp(d.fetch(:segment)),
      join_fields(%w[GS HB EXAMPLECLRHOUSE EXAMPLECLINIC 20260901 1200 101 X 005010X279A1]),
      *first_txn,
      *second_txn,
      join_fields(%w[GE 1 101]),
      join_fields(%w[IEA 1 000000101])
    ]
    join_segments(envelope)
  end

  def transaction_segments(member_token:, body_after_subscriber:, st_control:, payer_identifier: "EXPAYER01")
    rep = delimiters(:default).fetch(:repetition)
    el = delimiters(:default).fetch(:element)
    txn = [
      join_fields(%w[ST 271], st_control, "005010X279A1"),
      join_fields(%w[BHT 0022 11], st_control, "20260901", "1200"),
      join_fields(%w[HL 1], "", "20", "1"),
      join_fields([ "NM1", "PR", "2", "EXAMPLE COMMERCIAL PAYER", "", "", "", "", "PI", payer_identifier ]),
      join_fields(%w[HL 2 1 21 1]),
      join_fields([ "NM1", "1P", "2", "EXAMPLE BEHAVIORAL HEALTH CLINIC", "", "", "", "", "XX", "1999999992" ]),
      join_fields(%w[HL 3 2 22 0]),
      join_fields([ "NM1", "IL", "1", "", "", "", "", "", "", "MI", member_token ]),
      *body_after_subscriber.map { |segment| translate_segment(segment, profile: :default, rep: rep, el: el) }
    ]
    se_count = txn.length + 1
    txn + [ join_fields([ "SE", se_count.to_s, st_control ]) ]
  end

  def build_271_transaction(member_token:, segments_after_subscriber:, st_control: "9002", profile: :default)
    d = delimiters(profile)
    txn_head = [
      join_fields(%w[ST 271], st_control, "005010X279A1", profile: profile),
      join_fields(%w[BHT 0022 11], st_control, "20260901", "1200", profile: profile),
      join_fields(%w[HL 1], "", "20", "1", profile: profile),
      join_fields(
        [ "NM1", "PR", "2", "EXAMPLE COMMERCIAL PAYER", "", "", "", "", "PI", "EXPAYER01" ],
        profile: profile
      ),
      join_fields(%w[HL 2 1 21 1], profile: profile),
      join_fields(
        [ "NM1", "1P", "2", "EXAMPLE BEHAVIORAL HEALTH CLINIC", "", "", "", "", "XX", "1999999992" ],
        profile: profile
      ),
      join_fields(%w[HL 3 2 22 0], profile: profile),
      join_fields([ "NM1", "IL", "1", "", "", "", "", "", "", "MI", member_token ], profile: profile),
      *segments_after_subscriber.map { |segment| translate_segment(segment, profile: profile) }
    ]
    se_count = txn_head.length + 1
    txn = txn_head + [ join_fields([ "SE", se_count.to_s, st_control ], profile: profile) ]
    envelope = [
      d.fetch(:isa).chomp(d.fetch(:segment)),
      join_fields(
        %w[GS HB EXAMPLECLRHOUSE EXAMPLECLINIC 20260901 1200 101 X 005010X279A1],
        profile: profile
      ),
      *txn,
      join_fields(%w[GE 1 101], profile: profile),
      join_fields(%w[IEA 1 000000101], profile: profile)
    ]
    join_segments(envelope, profile: profile)
  end

  def join_fields(fields, *rest, profile: :default)
    separator = delimiters(profile).fetch(:element)
    [ *fields, *rest ].map(&:to_s).join(separator)
  end

  def translate_segment(segment, profile: :default, rep: nil, el: nil)
    return segment if profile == :default

    rep ||= delimiters(profile).fetch(:repetition)
    el ||= delimiters(profile).fetch(:element)
    segment.split("*", -1).join(el).gsub("^", rep)
  end

  def write_fixture(dir, member_token, content)
    File.binwrite(File.join(dir, "#{member_token}.271"), content)
  end

  def fixture_client(dir, clock: FIXED_CLOCK)
    Corvid::Rcm::FixtureClearinghouseClient.new(clock: clock, eligibility_fixture_dir: dir)
  end

  def build_eligibility_inquiry(member_token, service_date: Corvid::Rcm::ClaimFactory::SERVICE_DATE,
                                service_type_codes: %w[30], payer_identifier: "EXPAYER01")
    Corvid::Rcm::EligibilityInquiry.new(
      patient_identifier: "pt_elig_0001",
      payer_identifier: payer_identifier,
      member_identifier: member_token,
      service_date: service_date,
      provider_npi: Corvid::Rcm::ClaimFactory::BILLING_NPI,
      service_type_codes: service_type_codes
    )
  end

  def medicaid_inquiry_overrides
    { payer_identifier: "EXMEDICAID" }
  end

  def check_in_dir(dir, member_token, **inquiry_overrides)
    client = fixture_client(dir)
    client.check_eligibility(build_eligibility_inquiry(member_token, **inquiry_overrides))
  end
end
