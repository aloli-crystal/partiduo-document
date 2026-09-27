# SPDX-License-Identifier: AGPL-3.0-or-later

module Document
  # Règles des justificatifs (interne ; appelées par `Document::Api`).
  module Receipts
    alias FieldError = Partiduo::Api::FieldError

    # Types admis pour une prise de vue ou un fichier déposé (ADR-005 D8).
    CAPTURE_TYPES = %w[image/jpeg image/png image/heic application/pdf]
    # Types admis pour une facture reçue de la plateforme : en plus, le XML
    # lui-même quand la plateforme ne fournit pas de rendu lisible.
    RECEIVE_TYPES = CAPTURE_TYPES + %w[application/xml]
    # Types admis pour les données structurées (UBL, CII).
    DATA_TYPES = %w[application/xml]

    # Marques ISO BMFF d'une image HEIF/HEIC (photos des téléphones Apple).
    HEIF_BRANDS = %w[heic heix hevc hevx heim heis mif1 msf1]

    EXTENSIONS = {
      "image/jpeg"      => "jpg",
      "image/png"       => "png",
      "image/heic"      => "heic",
      "application/pdf" => "pdf",
      "application/xml" => "xml",
    }

    MAX_NOTE      = 2000
    MAX_SUPPLIER  =  255
    MAX_REFERENCE =  100
    MAX_DECIMALS  =    4

    # Type d'un contenu reconnu à ses premiers octets (le type annoncé par
    # le navigateur n'est pas cru) ; `nil` si aucun type admis.
    def self.sniff(bytes : Bytes) : String?
      return if bytes.empty?
      if starts_with?(bytes, "%PDF-".to_slice)
        "application/pdf"
      elsif starts_with?(bytes, Bytes[0xFF, 0xD8, 0xFF])
        "image/jpeg"
      elsif starts_with?(bytes, Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        "image/png"
      elsif heif?(bytes)
        "image/heic"
      elsif xml?(bytes)
        "application/xml"
      end
    end

    def self.heif?(bytes : Bytes) : Bool
      return false unless bytes.size >= 12 && bytes[4, 4] == "ftyp".to_slice
      box = Math.min(bytes.size, IO::ByteFormat::BigEndian.decode(UInt32, bytes[0, 4]).to_i)
      brands = [String.new(bytes[8, 4])]
      offset = 16
      while offset + 4 <= box
        brands << String.new(bytes[offset, 4])
        offset += 4
      end
      brands.any? { |brand| HEIF_BRANDS.includes?(brand) }
    end

    def self.xml?(bytes : Bytes) : Bool
      text = String.new(bytes[0, Math.min(bytes.size, 256)]).lchop("﻿").lstrip
      text.starts_with?('<') && !bytes.includes?(0_u8)
    end

    # Nom de fichier affiché : sans chemin ni caractère de contrôle ; un nom
    # vide (prise de vue, `blob`) devient `justificatif.<ext>`.
    def self.filename(name : String, content_type : String) : String
      clean = (name.gsub('\\', '/').split('/').last? || "").gsub(/[[:cntrl:]]/, "").strip
      clean = "" if clean == "blob"
      clean = "justificatif.#{EXTENSIONS[content_type]}" if clean.empty?
      clean.size > 200 ? clean[-200..] : clean
    end

    # Nom d'une version produite : `ticket.heic` → `ticket-preview.jpg`.
    def self.rendition_name(filename : String, variant : String) : String
      base = File.basename(filename, File.extname(filename))
      "#{base.presence || "justificatif"}-#{variant}.jpg"
    end

    # Valeurs contrôlées des compléments.
    record Details,
      supplier_name : String,
      supplier_card_id : Int64?,
      supplier_code : String,
      amount : BigDecimal?,
      currency_code : String,
      date : Time?,
      kind : String,
      note : String,
      reference : String

    # Contrôle les compléments ; la fiche citée par son quick code doit
    # exister et être lisible par l'acteur.
    def self.check_details(actor : Partiduo::Api::Actor, input : Api::DetailsInput,
                           errors : Array(FieldError)) : Details
      card = supplier_card(actor, input.supplier_code, errors)
      name = input.supplier_name.strip
      name = card.name if name.empty? && card
      too_long("supplier_name", name, MAX_SUPPLIER, errors)
      check_amount(input.amount, errors)

      currency = input.currency_code.strip.upcase
      unless currency.empty? || currency.matches?(/\A[A-Z]{3}\z/)
        errors << FieldError.new("currency_code", "document.errors.receipt.currency_code.invalid",
          {"value" => input.currency_code})
      end
      kind = input.kind.strip
      unless kind.empty? || Api::KINDS.includes?(kind)
        errors << FieldError.new("kind", "document.errors.receipt.kind.invalid", {"value" => kind})
      end
      note = input.note.strip
      too_long("note", note, MAX_NOTE, errors)
      reference = input.reference.strip
      too_long("reference", reference, MAX_REFERENCE, errors)

      Details.new(
        supplier_name: name, supplier_card_id: card.try(&.id), supplier_code: card.try(&.code) || "",
        amount: input.amount, currency_code: currency,
        date: input.date.try { |day| Time.utc(day.year, day.month, day.day) },
        kind: kind, note: note, reference: reference,
      )
    end

    # Fiche citée par son quick code : elle doit exister et être lisible.
    private def self.supplier_card(actor : Partiduo::Api::Actor, code : String?,
                                   errors : Array(FieldError)) : Partiduo::Api::Cards::CardView?
      code = code.try(&.strip).presence
      return if code.nil?
      card = actor.can?("cards.card.read") ? Partiduo::Api::Cards.card_by_code(actor, code) : nil
      errors << FieldError.new("supplier_code", "document.errors.receipt.supplier_code.unknown", {"value" => code}) unless card
      card
    end

    # Montant TTC : positif ou nul, quatre décimales au plus (convention C1 :
    # refusé, jamais arrondi).
    private def self.check_amount(amount : BigDecimal?, errors : Array(FieldError)) : Nil
      return if amount.nil?
      if amount < 0
        errors << FieldError.new("amount", "document.errors.receipt.amount.negative")
      elsif amount.scale > MAX_DECIMALS && amount != amount.round(MAX_DECIMALS)
        errors << FieldError.new("amount", "document.errors.receipt.amount.too_precise", {"max" => MAX_DECIMALS.to_s})
      elsif amount >= BigDecimal.new("1e16")
        errors << FieldError.new("amount", "document.errors.receipt.amount.too_large")
      end
    end

    private def self.too_long(field : String, value : String, max : Int32, errors : Array(FieldError)) : Nil
      return if value.size <= max
      errors << FieldError.new(field, "document.errors.receipt.#{field}.too_long", {"max" => max.to_s})
    end

    # Recopie les compléments contrôlés dans la ligne.
    def self.apply(receipt : Receipt, details : Details) : Receipt
      receipt.supplier_name = details.supplier_name
      receipt.supplier_card_id = details.supplier_card_id
      receipt.supplier_code = details.supplier_code
      receipt.amount = details.amount
      receipt.currency_code = details.currency_code
      receipt.document_date = details.date
      receipt.kind = details.kind
      receipt.note = details.note
      receipt.reference = details.reference
      receipt
    end

    # Justificatif verrouillé pour une modification (`SELECT … FOR UPDATE`).
    def self.lock!(id : Int64) : Receipt
      Receipt.all.lock.filter(id: id).first || raise Partiduo::Api::NotFound.new("receipt", id)
    end

    def self.find!(id : Int64) : Receipt
      Receipt.filter(id: id).first || raise Partiduo::Api::NotFound.new("receipt", id)
    end

    # Passe en « Rattaché ».
    def self.attach!(receipt : Receipt, entry_id : Int64? = nil, invoice_id : Int64? = nil,
                     by : Int64? = nil) : Receipt
      receipt.status = "attached"
      receipt.entry_id = entry_id
      receipt.invoice_id = invoice_id
      receipt.attached_at = Time.utc
      receipt.attached_by_id = by
      receipt.discarded_at = nil
      receipt.save!
      receipt
    end

    # Revient « À traiter ».
    def self.reopen!(receipt : Receipt) : Receipt
      receipt.status = "to_process"
      receipt.entry_id = nil
      receipt.invoice_id = nil
      receipt.attached_at = nil
      receipt.attached_by_id = nil
      receipt.discarded_at = nil
      receipt.save!
      receipt
    end

    def self.view(receipt : Receipt) : Api::ReceiptView
      Api::ReceiptView.new(
        id: receipt.id!.to_i64,
        source: receipt.source!,
        status: receipt.status!,
        supplier_name: receipt.supplier_name || "",
        supplier_card_id: receipt.supplier_card_id.try(&.to_i64),
        supplier_code: receipt.supplier_code || "",
        amount: receipt.amount,
        currency_code: receipt.currency_code || "",
        date: receipt.document_date,
        kind: receipt.kind || "",
        note: receipt.note || "",
        reference: receipt.reference || "",
        filename: receipt.filename!,
        content_type: receipt.content_type!,
        byte_size: receipt.byte_size!.to_i64,
        original_attachment_id: receipt.original_attachment_id!.to_i64,
        preview_attachment_id: receipt.preview_attachment_id.try(&.to_i64),
        thumbnail_attachment_id: receipt.thumbnail_attachment_id.try(&.to_i64),
        data_attachment_id: receipt.data_attachment_id.try(&.to_i64),
        sha256: receipt.sha256!,
        external_ref: receipt.external_ref,
        entry_id: receipt.entry_id.try(&.to_i64),
        invoice_id: receipt.invoice_id.try(&.to_i64),
        attached_at: receipt.attached_at,
        attached_by_id: receipt.attached_by_id.try(&.to_i64),
        discarded_at: receipt.discarded_at,
        captured_by_id: receipt.captured_by_id.try(&.to_i64),
        created_at: receipt.created_at!,
      )
    end

    private def self.starts_with?(bytes : Bytes, prefix : Bytes) : Bool
      bytes.size >= prefix.size && bytes[0, prefix.size] == prefix
    end
  end
end
