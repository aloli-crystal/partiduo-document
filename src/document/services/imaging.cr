# SPDX-License-Identifier: AGPL-3.0-or-later

module Document
  # Vignette et version réduite d'un justificatif, produites par le serveur
  # (ADR-005 D8) : JPEG orienté selon l'EXIF de la photo, sans métadonnées ;
  # la version réduite d'une photo HEIC en est la conversion. Première page
  # pour un PDF. L'original n'est jamais modifié.
  #
  # Le rendu est confié à un outil du système (DECISIONS D-DOC-005) : libvips
  # (`vipsthumbnail`), sinon ImageMagick (`magick`). Sans outil, ou si l'outil
  # échoue, le justificatif est conservé sans vignette : l'interface affiche
  # alors un pictogramme et l'original reste téléchargeable.
  module Imaging
    # Plus grand côté de la vignette (carte de la boîte, 3× la taille CSS).
    THUMBNAIL_SIZE = 320
    # Plus grand côté de la version réduite (affichée à côté de la saisie).
    PREVIEW_SIZE = 1600
    # Durée maximale d'un rendu.
    TIMEOUT = 30.seconds

    # Formats de fichier que l'outil sait lire, par type MIME (préfixe de
    # format explicite d'ImageMagick : le contenu a déjà été contrôlé).
    FORMATS = {
      "image/jpeg"      => "jpeg",
      "image/png"       => "png",
      "image/heic"      => "heic",
      "application/pdf" => "pdf",
    }

    # Versions produites (JPEG) ; `nil` : non produite.
    record Renditions, preview : Bytes?, thumbnail : Bytes?

    # Outil de rendu : réduit `input` (type `content_type`) à `size` pixels
    # au plus sur son plus grand côté, en JPEG. `nil` en cas d'échec.
    abstract class Renderer
      abstract def name : String
      abstract def render(input : String, content_type : String, size : Int32) : Bytes?

      # Exécute l'outil avec un délai maximal ; vrai s'il a réussi.
      protected def run(command : String, args : Array(String)) : Bool
        process = Process.new(command, args, output: Process::Redirect::Close, error: Process::Redirect::Close)
        done = Channel(Process::Status).new(1)
        spawn { done.send(process.wait) }
        select
        when status = done.receive
          status.success?
        when timeout(TIMEOUT)
          process.terminate rescue nil
          false
        end
      rescue IO::Error | File::Error
        false
      end

      protected def with_output(& : String -> Bool) : Bytes?
        path = File.tempname("partiduo-document", ".jpg")
        ok = yield path
        ok && File.exists?(path) && File.size(path) > 0 ? File.read(path).to_slice : nil
      ensure
        path.try { |file| File.delete?(file) }
      end
    end

    # libvips : `vipsthumbnail` réduit sans agrandir, applique l'orientation
    # EXIF, lit HEIC (libheif) et PDF (poppler) quand libvips les porte.
    class VipsRenderer < Renderer
      def initialize(@command : String)
      end

      def name : String
        "vipsthumbnail"
      end

      def render(input : String, content_type : String, size : Int32) : Bytes?
        with_output do |output|
          run(@command, [input, "--size", "#{size}x#{size}>", "-o", "#{output}[Q=82,strip,background=255]"])
        end
      end
    end

    # ImageMagick 7 : format d'entrée imposé (`jpeg:`, `pdf:`…), première
    # page seulement, orientation EXIF appliquée, fond blanc.
    class MagickRenderer < Renderer
      def initialize(@command : String)
      end

      def name : String
        "magick"
      end

      def render(input : String, content_type : String, size : Int32) : Bytes?
        format = FORMATS[content_type]? || return
        with_output do |output|
          run(@command, ["#{format}:#{input}[0]", "-auto-orient", "-thumbnail", "#{size}x#{size}>",
                         "-background", "white", "-flatten", "-strip", "-quality", "82", "jpeg:#{output}"])
        end
      end
    end

    # Aucun outil : pas de vignette.
    class NullRenderer < Renderer
      def name : String
        "none"
      end

      def render(input : String, content_type : String, size : Int32) : Bytes?
        nil
      end
    end

    @@renderer : Renderer?

    # Outil retenu : `PARTIDUO_DOCUMENT_RENDERER` (`vips`, `magick`, `none`),
    # sinon le premier trouvé dans le `PATH`.
    def self.renderer : Renderer
      @@renderer ||= detect
    end

    # Remplace l'outil (specs) ; `nil` : nouvelle détection.
    def self.renderer=(renderer : Renderer?) : Renderer?
      @@renderer = renderer
    end

    def self.detect(choice : String? = ENV["PARTIDUO_DOCUMENT_RENDERER"]?) : Renderer
      vips = -> { Process.find_executable("vipsthumbnail").try { |path| VipsRenderer.new(path).as(Renderer) } }
      magick = -> { Process.find_executable("magick").try { |path| MagickRenderer.new(path).as(Renderer) } }
      found = case choice
              when "vips"   then vips.call
              when "magick" then magick.call
              when "none"   then nil
              else               vips.call || magick.call
              end
      found || NullRenderer.new
    end

    # Vignette et version réduite de `bytes`. Un format que l'outil ne sait
    # pas lire ne produit rien.
    def self.renditions(bytes : Bytes, content_type : String) : Renditions
      return Renditions.new(nil, nil) unless FORMATS.has_key?(content_type)
      input = File.tempname("partiduo-document", ".#{FORMATS[content_type]}")
      File.write(input, bytes)
      Renditions.new(renderer.render(input, content_type, PREVIEW_SIZE), renderer.render(input, content_type, THUMBNAIL_SIZE))
    ensure
      input.try { |file| File.delete?(file) }
    end
  end
end
