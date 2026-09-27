# SPDX-License-Identifier: AGPL-3.0-or-later

require "base64"

# Exécute le bloc avec une autre liste de modules actifs (`PARTIDUO_MODULES`),
# puis restaure la configuration. Sans ligne dans `modules_activation`, c'est
# l'ensemble actif de l'instance (DECISIONS D-018).
def with_active_modules(codes : String?, &)
  previous = ENV["PARTIDUO_MODULES"]?
  codes.nil? ? ENV.delete("PARTIDUO_MODULES") : (ENV["PARTIDUO_MODULES"] = codes)
  yield
ensure
  previous.nil? ? ENV.delete("PARTIDUO_MODULES") : (ENV["PARTIDUO_MODULES"] = previous)
end

module Document
  module SpecSupport
    alias Api = Document::Api

    # Plus petits fichiers valides de chaque format (contenu reconnu par sa
    # signature, rendu par libvips ou ImageMagick).
    PNG = Base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")
    PDF = "%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj 2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj " \
          "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 280]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n".to_slice
    XML  = %(<?xml version="1.0" encoding="UTF-8"?><Invoice xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"><ID>FB-1</ID></Invoice>).to_slice
    HEIC = Bytes[0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63, 0, 0, 0, 0, 0x6D, 0x69, 0x66, 0x31, 0x68, 0x65, 0x69, 0x63, 0, 0, 0, 8]

    # JPEG réel (100 × 140, orienté), produit par l'outil du système s'il
    # existe ; sinon un en-tête JPEG minimal (le rendu échoue alors).
    def self.jpeg : Bytes
      @@jpeg ||= begin
        path = File.tempname("partiduo-document-spec", ".jpg")
        if (magick = Process.find_executable("magick")) &&
           Process.run(magick, ["-size", "100x140", "gradient:white-gray", "-quality", "80", path]).success?
          File.read(path).to_slice
        else
          Bytes[0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0xFF, 0xD9]
        end
      ensure
        path.try { |file| File.delete?(file) }
      end
    end

    @@jpeg : Bytes?

    # Outil de rendu factice : une « vignette » connue, sans outil externe.
    class FakeRenderer < Document::Imaging::Renderer
      getter calls = [] of {String, Int32}

      def name : String
        "fake"
      end

      def render(input : String, content_type : String, size : Int32) : Bytes?
        @calls << {content_type, size}
        Bytes[0xFF, 0xD8, 0xFF, 0xE0, size.to_u8!, 0xFF, 0xD9]
      end
    end

    # Outil qui échoue toujours.
    class FailingRenderer < Document::Imaging::Renderer
      def name : String
        "failing"
      end

      def render(input : String, content_type : String, size : Int32) : Bytes?
        nil
      end
    end

    def self.admin : Partiduo::Api::Actor
      Partiduo::Api::Actor.user(1_i64, [Api::READ, Api::WRITE, Api::ATTACHMENT_READ, Api::ATTACHMENT_WRITE,
                                        "cards.card.read", "vat.rate.read", "accounting.entry.read", "accounting.entry.post",
                                        "accounting.entry.cancel", "accounting.ledger.read", "invoicing.invoice.read"])
    end

    def self.reader : Partiduo::Api::Actor
      Partiduo::Api::Actor.user(2_i64, [Api::READ, Api::ATTACHMENT_READ])
    end

    def self.activate : Nil
      Partiduo::Api::Modules.activate(Partiduo::Api::Actor.system, Document::CODE).value!
      nil
    end

    def self.capture(content : Bytes = PNG, filename : String = "ticket.png",
                     details : Api::DetailsInput = Api::DetailsInput.new, source : String? = nil,
                     actor : Partiduo::Api::Actor = admin) : Api::ReceiptView
      Api.capture(actor, Api::CaptureInput.new(filename: filename, content: content, source: source, details: details)).value!
    end

    def self.d(text : String) : BigDecimal
      BigDecimal.new(text)
    end

    def self.date(text : String) : Time
      Time.parse_utc(text, "%Y-%m-%d")
    end

    # Corps `multipart/form-data` d'un formulaire avec un fichier.
    def self.multipart(fields : Hash(String, String), file : {String, String, Bytes}?) : {String, String}
      io = IO::Memory.new
      boundary = "PartiduoDocumentSpecBoundary"
      HTTP::FormData.build(io, boundary) do |builder|
        fields.each { |name, value| builder.field(name, value) }
        if file
          builder.file(file[0], IO::Memory.new(file[2]), HTTP::FormData::FileMetadata.new(filename: file[1]))
        end
      end
      {io.to_s, "multipart/form-data; boundary=#{boundary}"}
    end

    # Envoi d'un formulaire multipart par le navigateur de test (cookies
    # gardés).
    def self.upload(browser : PartiduoUi::Browser, path : String, fields : Hash(String, String),
                    file : {String, String, Bytes}?) : Marten::HTTP::Response
      body, content_type = multipart(fields, file)
      client = Marten::Spec::Client.new
      browser.jar.each { |name, value| client.cookies[name] = value }
      response = client.post(path, data: body, content_type: content_type, headers: browser.headers)
      client.cookies.each { |(name, value)| value.empty? ? browser.jar.delete(name) : (browser.jar[name] = value) }
      response
    end
  end
end

Spec.before_each do
  Document::Imaging.renderer = Document::SpecSupport::FakeRenderer.new
end
