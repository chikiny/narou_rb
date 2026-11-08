# frozen_string_literal: true

#
# メールの容量制限（Gmail は 25MB）に収まるよう、EPUB の画像を縮小・JPEG 化した複製を作る
#
# 元のファイルは変更しない。画像を端末の画面に収まる大きさに縮め、JPEG にしてから zip を作り直す。
# 弱い段階から順に試し、上限に収まった最初のものを返す。どの段階でも収まらなければ nil を返す。
# ImageMagick の convert コマンドを使う。
#

require "open3"
require "zip"
require "zlib"

module EbookShrinker
  # 試す順。最後が最大の圧縮（Kindle Colorsoft の画面 1264x1680 を基準にする）
  STEPS = [
    { geometry: "1264x1680", quality: 85 },
    { geometry: "1264x1680", quality: 60 },
    { geometry: "948x1260", quality: 40 },
  ].freeze

  IMAGE_EXT = /\.(?:png|jpe?g|gif|bmp|webp)\z/i
  TEXT_EXT = /\.(?:opf|xhtml|html?|css|ncx|xml)\z/i

  class ConvertError < StandardError; end

  # path: 送るファイル。step: 使った STEPS の番号（縮小しなかったときは nil）
  Result = Struct.new(:path, :step)

  module_function

  def shrink(src, limit:, workdir:)
    return Result.new(src, nil) if File.size(src) <= limit
    entries = read_entries(src)
    STEPS.each_with_index do |step, index|
      out = File.join(workdir, "shrunk_#{index}_#{File.basename(src)}")
      write_epub(out, convert_entries(entries, step))
      return Result.new(out, index) if File.size(out) <= limit
    end
    nil
  end

  def read_entries(src)
    Zip::File.open(src) do |zip|
      zip.entries.reject(&:directory?).map { |e| [e.name, e.get_input_stream.read] }
    end
  end

  # 画像を変換し、名前が変わったものの参照（manifest・本文・CSS）を書き換える
  def convert_entries(entries, step)
    names = entries.map(&:first)
    renames = {}
    converted = entries.map do |name, data|
      next [name, data] unless name =~ IMAGE_EXT
      new_name = jpeg_name(name, names, renames)
      renames[name] = new_name if new_name != name
      [new_name, to_jpeg(data, step)]
    end
    return converted if renames.empty?
    converted.map do |name, data|
      next [name, data] unless name =~ TEXT_EXT
      text = data.dup.force_encoding(Encoding::UTF_8)
      text.force_encoding(Encoding::BINARY) unless text.valid_encoding?
      [name, rewrite_references(text, renames)]
    end
  end

  # 拡張子を .jpg にした名前。同じフォルダに同じ名前があれば重ならない名前にする
  def jpeg_name(name, names, renames)
    return name if name =~ /\.jpe?g\z/i
    base = name.sub(IMAGE_EXT, "")
    candidate = "#{base}.jpg"
    taken = names + renames.values
    candidate = "#{base}_#{File.extname(name).delete('.')}.jpg" if taken.include?(candidate)
    candidate
  end

  def rewrite_references(text, renames)
    renames.each do |from, to|
      from_base = File.basename(from)
      to_base = File.basename(to)
      text = text.gsub(/(?<=["'\/(])#{Regexp.escape(from_base)}(?=["')#?])/, to_base)
    end
    # manifest の media-type を JPEG に合わせる
    text.gsub(/<item\b[^>]*>/) do |item|
      next item unless item =~ /href="[^"]*\.jpe?g"/i
      item.sub(/media-type="image\/[^"]+"/, 'media-type="image/jpeg"')
    end
  end

  def to_jpeg(data, step)
    args = ["convert", "-", "-background", "white", "-flatten",
            "-resize", "#{step[:geometry]}>", "-strip", "-quality", step[:quality].to_s, "jpg:-"]
    out, err, status = Open3.capture3(*args, stdin_data: data, binmode: true)
    raise ConvertError, "画像の変換に失敗しました: #{err.strip}" unless status.success?
    out
  end

  # mimetype は先頭に無圧縮で置く（EPUB の決まり）。ほかは最大の圧縮率で格納する
  def write_epub(out, entries)
    File.delete(out) if File.exist?(out)
    Zip::OutputStream.open(out) do |zos|
      mimetype = entries.find { |name, _| name == "mimetype" }
      if mimetype
        zos.put_next_entry("mimetype", nil, nil, Zip::Entry::STORED)
        zos.write mimetype[1]
      end
      entries.each do |name, data|
        next if name == "mimetype"
        zos.put_next_entry(name, nil, nil, Zip::Entry::DEFLATED, Zlib::BEST_COMPRESSION)
        zos.write data
      end
    end
  end
end
