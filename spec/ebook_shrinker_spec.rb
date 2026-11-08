# frozen_string_literal: true

require "tmpdir"
require "open3"
require "zip"
require "ebook_shrinker"

describe EbookShrinker do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def magick_available?
    system("convert", "-version", out: File::NULL, err: File::NULL)
  end

  before do
    skip "ImageMagick（convert）がないため省略" unless magick_available?
  end

  # 細かい模様の PNG（圧縮しにくい）を作る
  def noisy_png(width, height)
    out = File.join(@dir, "noise_#{width}x#{height}_#{rand(1 << 30)}.png")
    system("convert", "-size", "#{width}x#{height}", "xc:", "+noise", "Random", out, exception: true)
    File.binread(out)
  end

  def build_epub(path, images)
    opf_items = images.keys.map.with_index do |name, i|
      %(<item id="img#{i}" href="image/#{name}" media-type="image/png"/>)
    end
    imgs = images.keys.map { |name| %(<p><img src="../image/#{name}" alt=""/></p>) }.join
    Zip::OutputStream.open(path) do |zos|
      zos.put_next_entry("mimetype", nil, nil, Zip::Entry::STORED)
      zos.write "application/epub+zip"
      zos.put_next_entry("item/standard.opf")
      zos.write %(<package><manifest>#{opf_items.join}</manifest></package>)
      zos.put_next_entry("item/xhtml/0001.xhtml")
      zos.write %(<html><body>#{imgs}</body></html>)
      images.each do |name, data|
        zos.put_next_entry("item/image/#{name}")
        zos.write data
      end
    end
    path
  end

  def entries(path)
    Zip::File.open(path) { |z| z.entries.map { |e| [e.name, e.get_input_stream.read] }.to_h }
  end

  def first_entry(path)
    Zip::File.open(path) { |z| e = z.entries.first; [e.name, e.compression_method] }
  end

  it "returns the original file when it is already small enough" do
    src = build_epub(File.join(@dir, "small.epub"), "a.png" => noisy_png(100, 100))
    result = EbookShrinker.shrink(src, limit: 10_000_000, workdir: @dir)
    expect(result.path).to eq src
    expect(result.step).to be_nil
  end

  it "converts images to resized JPEG and rewrites references when over the limit" do
    src = build_epub(File.join(@dir, "big.epub"), "0001.png" => noisy_png(2000, 2600))
    limit = File.size(src) - 1
    result = EbookShrinker.shrink(src, limit: limit, workdir: @dir)
    expect(result).not_to be_nil
    expect(File.size(result.path)).to be <= limit
    expect(result.step).to eq 0
    files = entries(result.path)
    expect(files.keys).to include("item/image/0001.jpg")
    expect(files.keys).not_to include("item/image/0001.png")
    expect(files["item/standard.opf"]).to include(%(href="image/0001.jpg" media-type="image/jpeg"))
    expect(files["item/xhtml/0001.xhtml"]).to include(%(src="../image/0001.jpg"))
    expect(first_entry(result.path)).to eq ["mimetype", Zip::Entry::STORED]
    out, = Open3.capture2("identify", "-format", "%w %h", File.join(@dir, "check.jpg").tap { |p| File.binwrite(p, files["item/image/0001.jpg"]) })
    w, h = out.split.map(&:to_i)
    expect(w).to be <= 1264
    expect(h).to be <= 1680
  end

  it "uses a stronger step when the first one is not enough" do
    src = build_epub(File.join(@dir, "big.epub"), "0001.png" => noisy_png(2000, 2600))
    first = EbookShrinker.shrink(src, limit: File.size(src) - 1, workdir: @dir)
    result = EbookShrinker.shrink(src, limit: File.size(first.path) - 1, workdir: @dir)
    expect(result).not_to be_nil
    expect(result.step).to be > 0
  end

  it "returns nil when even the strongest step is over the limit" do
    src = build_epub(File.join(@dir, "big.epub"), "0001.png" => noisy_png(2000, 2600))
    expect(EbookShrinker.shrink(src, limit: 1000, workdir: @dir)).to be_nil
  end

  it "does not clash with an existing jpg of the same base name" do
    src = build_epub(File.join(@dir, "big.epub"), "0001.png" => noisy_png(1500, 1500), "0001.jpg" => noisy_png(10, 10))
    result = EbookShrinker.shrink(src, limit: File.size(src) - 1, workdir: @dir)
    files = entries(result.path)
    jpgs = files.keys.grep(%r{\Aitem/image/})
    expect(jpgs.size).to eq 2
    expect(files["item/xhtml/0001.xhtml"].scan(/src="([^"]+)"/).flatten.uniq.size).to eq 2
  end
end
