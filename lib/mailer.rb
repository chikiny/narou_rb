# frozen_string_literal: true

#
# Copyright 2013 whiteleaf. All rights reserved.
#

require "yaml"
require "singleton"
require "tmpdir"
require_relative "narou"
require_relative "ebook_shrinker"

class Mailer
  include Singleton

  SETTING_FILE = "mail_setting.yaml"
  # Gmail の上限は添付を base64 にした後で 25MB。base64 で約 4/3 倍になるので、元の大きさで 18MB までにする
  DEFAULT_SHRINK_LIMIT_BYTES = 18_000_000

  class SettingNotFound < StandardError; end
  class SettingUncompleteError < StandardError; end

  attr_reader :error_message

  def self.create
    this = instance
    this.clear
    setting_file_path = File.join(Narou.root_dir, SETTING_FILE)
    if File.exist?(setting_file_path)
      options = YAML.unsafe_load_file(setting_file_path)
      unless options.delete(:complete)
        raise SettingUncompleteError, "設定ファイルの書き換えが終了していないようです。\n" +
                                      "設定ファイルは #{setting_file_path} にあります"
      end
      this.options = options
    else
      raise SettingNotFound
    end
    this
  end

  def initialize
    @options = {}
    @error_message = ""
    @too_large = false
  end

  # 直前の send が、画像を縮小してもメールの上限を超えたために送れなかったか
  def too_large?
    @too_large
  end

  def clear
    @options.clear
  end

  def options=(options)
    @options.merge!(options)
  end

  def send(id, message, attached_file_path = nil)
    gem "mail", "2.6.6"
    require "pony"
    require_relative "mail_encoding_patch"
    @error_message = ""
    @too_large = false
    params = @options.dup
    limit = params.delete(:shrink_limit_bytes) || DEFAULT_SHRINK_LIMIT_BYTES
    params[:body] = message
    params[:charset] = "UTF-8"
    params[:text_part_charset] = "UTF-8"
    if attached_file_path
      # Send to Kindle は添付ファイル名（拡張子を除く）を本の題名にするため、
      # 小説 ID ではなく電子書籍ファイルの名前のまま添付する
      basename = File.basename(attached_file_path)
      if File.size(attached_file_path) <= limit
        params[:attachments] = { basename => File.binread(attached_file_path) }
        return deliver(params)
      end
      Dir.mktmpdir do |workdir|
        result = EbookShrinker.shrink(attached_file_path, limit: limit, workdir: workdir)
        unless result
          @too_large = true
          @error_message = "#{basename} は画像を縮小してもメールの上限（#{limit / 1_000_000}MB）を超えるため送れません"
          return false
        end
        params[:attachments] = { basename => File.binread(result.path) }
      end
    end
    deliver(params)
  rescue EbookShrinker::ConvertError => e
    @error_message = e.message
    false
  end

  private

  def deliver(params)
    Pony.mail(params)
    true
  rescue StandardError => e
    @error_message = e.message
    false
  end
end
