# frozen_string_literal: true

#
# mail 2.6.6 の encoded-word（=?UTF-8?B?...?=）の区切り方を直す
#
# mail 2.6.6 は値全体を base64 にしてから 60 文字ごとに区切るため、マルチバイト文字の途中で
# encoded-word が切れる。長い添付ファイル名（英字と日本語が混ざる題名など）で 1 文字欠けたり、
# Pony が添付を名前で取り出せず undefined method 'add_content_id' for nil になったりする。
# 文字の境目で 45 バイト（base64 で 60 文字）以内に区切ってから、区切りごとに base64 にする。
#

require "base64"

module MailEncodingPatch
  MAX_WORD_BYTES = 45

  def b_value_encode(encoded_str, encoding = nil)
    return super if encoded_str.to_s.ascii_only?
    str = encoded_str.to_s
    charset = str.encoding.to_s
    chunks = []
    current = +""
    str.each_char do |char|
      if !current.empty? && current.bytesize + char.bytesize > MAX_WORD_BYTES
        chunks << current
        current = +""
      end
      current << char
    end
    chunks << current unless current.empty?
    chunks.map { |chunk| "=?#{charset}?B?#{Base64.strict_encode64(chunk)}?=" }.join(" ")
  end
end

Mail::Encodings.singleton_class.prepend(MailEncodingPatch)
