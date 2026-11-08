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

  it "sends no attachment when no file is given" do
    params = capture_params { mailer.send(5, "msg") }
    expect(params).not_to have_key(:attachments)
  end
end
