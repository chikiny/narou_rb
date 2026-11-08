# frozen_string_literal: true

require "tmpdir"
require "mailer"

# 実際の送信はしないので、pony（net/smtp に依存）は読み込まずに差し替える
module Pony
  def self.mail(_params); end
end unless defined?(Pony)

describe Mailer do
  let(:mailer) do
    m = Mailer.instance
    m.clear
    m.options = { to: "to@example.com", from: "from@example.com", via: :test }
    allow(m).to receive(:require).and_call_original
    allow(m).to receive(:require).with("pony").and_return(true)
    m
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def capture_params
    captured = nil
    allow(Pony).to receive(:mail) { |params| captured = params }
    yield
    captured
  end

  it "attaches the ebook under its own file name so Send to Kindle titles it by that name" do
    path = File.join(@dir, "[作者] 作品名【WEB版】.epub")
    File.binwrite(path, "dummy")
    params = capture_params { expect(mailer.send(5, "msg", path)).to be true }
    expect(params[:attachments].keys).to eq ["[作者] 作品名【WEB版】.epub"]
    expect(params[:attachments].values).to eq ["dummy"]
  end

  it "keeps a split file's own name" do
    path = File.join(@dir, "[作者] 作品名_2.epub")
    File.binwrite(path, "dummy")
    params = capture_params { mailer.send(5, "msg", path) }
    expect(params[:attachments].keys).to eq ["[作者] 作品名_2.epub"]
  end

  it "sends a shrunk copy under the same name when the file is over the limit" do
    path = File.join(@dir, "[作者] 大きい作品.epub")
    File.binwrite(path, "x" * 100)
    shrunk = File.join(@dir, "shrunk.epub")
    File.binwrite(shrunk, "small")
    mailer.options = { shrink_limit_bytes: 50 }
    allow(EbookShrinker).to receive(:shrink).and_return(EbookShrinker::Result.new(shrunk, 1))
    params = capture_params { expect(mailer.send(5, "msg", path)).to be true }
    expect(EbookShrinker).to have_received(:shrink).with(path, limit: 50, workdir: anything)
    expect(params[:attachments]).to eq("[作者] 大きい作品.epub" => "small")
    expect(params).not_to have_key(:shrink_limit_bytes)
    expect(mailer.too_large?).to be false
  end

  it "does not send and reports too large when shrinking cannot fit the limit" do
    path = File.join(@dir, "[作者] 大きい作品.epub")
    File.binwrite(path, "x" * 100)
    mailer.options = { shrink_limit_bytes: 50 }
    allow(EbookShrinker).to receive(:shrink).and_return(nil)
    expect(Pony).not_to receive(:mail)
    expect(mailer.send(5, "msg", path)).to be false
    expect(mailer.too_large?).to be true
    expect(mailer.error_message).to include("[作者] 大きい作品.epub")
  end

  it "does not shrink a file within the default limit" do
    path = File.join(@dir, "[作者] 作品.epub")
    File.binwrite(path, "dummy")
    allow(EbookShrinker).to receive(:shrink)
    params = capture_params { mailer.send(5, "msg", path) }
    expect(EbookShrinker).not_to have_received(:shrink)
    expect(params[:attachments].values).to eq ["dummy"]
  end

  it "sends no attachment when no file is given" do
    params = capture_params { mailer.send(5, "msg") }
    expect(params).not_to have_key(:attachments)
  end
end
