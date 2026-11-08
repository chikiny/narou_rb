# frozen_string_literal: true

gem "mail", "2.6.6"
require "mail"
require "mail_encoding_patch"

describe "mail の encoded-word の区切り" do
  long_mixed = "[恋狸] TS転生した私が所属するVtuber事務所のライバーを全員堕としにいく話.epub"

  def words(encoded)
    encoded.scan(/=\?UTF-8\?B\?([^?]+)\?=/i).flatten
  end

  it "splits B-encoded words on character boundaries" do
    encoded = Mail::Encodings.b_value_encode(long_mixed, "UTF-8")
    ws = words(encoded)
    expect(ws.size).to be > 1
    ws.each do |w|
      expect(w.size).to be <= 60
      expect(w.unpack1("m").force_encoding("UTF-8")).to be_valid_encoding
    end
    expect(ws.map { |w| w.unpack1("m").force_encoding("UTF-8") }.join).to eq long_mixed
  end

  it "keeps an attachment findable under a long mixed name" do
    mail = Mail.new
    mail.attachments[long_mixed] = "x"
    expect(mail.attachments[long_mixed]).not_to be_nil
    expect(Mail.read_from_string(mail.to_s).attachments.first.filename).to eq long_mixed
  end

  it "leaves ASCII-only values untouched" do
    expect(Mail::Encodings.b_value_encode("plain.epub", "UTF-8")).to eq "plain.epub"
  end
end
