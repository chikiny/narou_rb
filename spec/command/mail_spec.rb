# frozen_string_literal: true

require "stringio"
require "commandline"
require "narou_logger"

describe Command::Mail do
  let(:io) { StringIO.new.tap { |s| def s.error(msg) puts(msg) end } }
  let(:cmd) { Command::Mail.new.tap { |c| c.stream_io = io } }
  let(:mailer) { double("mailer", error_message: "上限を超えます") }

  it "reconverts without illustrations and resends once when too large" do
    allow(cmd).to receive(:send_ebooks).and_return(:too_large, :sent)
    allow(cmd).to receive(:disable_illust_and_convert).with(7).and_return(true)
    result = cmd.deliver_novel(mailer, 7, ["/a.epub"]) { ["/b.epub"] }
    expect(result).to eq :sent
    expect(cmd).to have_received(:send_ebooks).with(mailer, 7, ["/a.epub"]).ordered
    expect(cmd).to have_received(:send_ebooks).with(mailer, 7, ["/b.epub"]).ordered
  end

  it "gives up as too large when illustrations are already disabled" do
    allow(cmd).to receive(:send_ebooks).and_return(:too_large)
    allow(cmd).to receive(:disable_illust_and_convert).and_return(false)
    expect(cmd.deliver_novel(mailer, 7, ["/a.epub"]) { raise "呼ばれない" }).to eq :too_large
    expect(cmd).to have_received(:send_ebooks).once
  end

  it "does not reconvert on other errors or for hotentry" do
    allow(cmd).to receive(:send_ebooks).and_return(:error)
    allow(cmd).to receive(:disable_illust_and_convert)
    expect(cmd.deliver_novel(mailer, 7, ["/a.epub"]) { [] }).to eq :error
    allow(cmd).to receive(:send_ebooks).and_return(:too_large)
    expect(cmd.deliver_novel(mailer, "hotentry", ["/h.epub"], hotentry: true) { [] }).to eq :too_large
    expect(cmd).not_to have_received(:disable_illust_and_convert)
  end

  it "stops at the first failure and reports too large from the mailer" do
    allow(mailer).to receive(:send).and_return(true, false)
    allow(mailer).to receive(:too_large?).and_return(true)
    expect(cmd.send_ebooks(mailer, 7, ["/a.epub", "/a_2.epub", "/a_3.epub"])).to eq :too_large
    expect(mailer).to have_received(:send).twice
  end
end
