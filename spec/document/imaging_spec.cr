# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private def real_renderer : Document::Imaging::Renderer?
  renderer = Document::Imaging.detect
  renderer.is_a?(Document::Imaging::NullRenderer) ? nil : renderer
end

# Fichier produit par ImageMagick (HEIC : libheif), `nil` si l'outil manque.
private def generated(extension : String) : Bytes?
  magick = Process.find_executable("magick") || return
  path = File.tempname("partiduo-document-spec", ".#{extension}")
  return unless Process.run(magick, ["-size", "600x800", "gradient:white-gray", "-quality", "80", path]).success?
  File.read(path).to_slice
ensure
  path.try { |file| File.delete?(file) }
end

private def jpeg_size(bytes : Bytes) : {Int32, Int32}
  # Balayage des segments JPEG jusqu'au SOF0/SOF2.
  index = 2
  while index + 9 < bytes.size
    marker = bytes[index + 1]
    length = (bytes[index + 2].to_i << 8) | bytes[index + 3]
    if marker.in?(0xC0_u8, 0xC2_u8)
      return {(bytes[index + 7].to_i << 8) | bytes[index + 8], (bytes[index + 5].to_i << 8) | bytes[index + 6]}
    end
    index += 2 + length
  end
  {0, 0}
end

describe "Justificatifs : vignette et version réduite produites par le serveur" do
  it "reconnaît les formats à leur signature" do
    rules = Document::Receipts
    rules.sniff(Document::SpecSupport::PDF).should eq("application/pdf")
    rules.sniff(Document::SpecSupport::PNG).should eq("image/png")
    rules.sniff(Document::SpecSupport.jpeg).should eq("image/jpeg")
    rules.sniff(Document::SpecSupport::HEIC).should eq("image/heic")
    rules.sniff(Document::SpecSupport::XML).should eq("application/xml")
    # Conteneur ISO BMFF qui n'est pas une image HEIF (vidéo MP4).
    rules.sniff(Bytes[0, 0, 0, 0x14, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D, 0, 0, 0, 0, 0x6D, 0x70, 0x34, 0x31]).should be_nil
    rules.sniff("GIF89a".to_slice).should be_nil
    rules.filename("C:\\Users\\moi\\Photos\\ticket.jpg", "image/jpeg").should eq("ticket.jpg")
    rules.filename("blob", "image/png").should eq("justificatif.png")
    rules.rendition_name("IMG_1.HEIC", "preview").should eq("IMG_1-preview.jpg")
  end

  it "choisit l'outil du système, ou aucun" do
    Document::Imaging.detect("none").should be_a(Document::Imaging::NullRenderer)
    Document::Imaging.renditions(Document::SpecSupport::PDF, "text/plain").preview.should be_nil
  end

  it "réduit une photo JPEG sans l'agrandir" do
    renderer = real_renderer
    photo = generated("jpg")
    next pending!("ni libvips ni ImageMagick") if renderer.nil? || photo.nil?
    Document::Imaging.renderer = renderer
    renditions = Document::Imaging.renditions(photo, "image/jpeg")
    thumbnail = renditions.thumbnail || raise("vignette absente")
    Document::Receipts.sniff(thumbnail).should eq("image/jpeg")
    jpeg_size(thumbnail).should eq({240, 320})
    jpeg_size(renditions.preview || raise("version réduite absente")).should eq({600, 800})
  end

  it "convertit une photo HEIC en JPEG et rend la première page d'un PDF" do
    renderer = real_renderer
    heic = generated("heic")
    next pending!("outil de rendu HEIC absent") if renderer.nil? || heic.nil? || Document::Receipts.sniff(heic) != "image/heic"
    Document::Imaging.renderer = renderer
    preview = Document::Imaging.renditions(heic, "image/heic").preview || raise("conversion absente")
    Document::Receipts.sniff(preview).should eq("image/jpeg")
    jpeg_size(preview).should eq({600, 800})

    pdf = Document::Imaging.renditions(Document::SpecSupport::PDF, "application/pdf").thumbnail
    next pending!("rendu PDF indisponible (poppler, Ghostscript)") if pdf.nil?
    Document::Receipts.sniff(pdf).should eq("image/jpeg")
  end
end
