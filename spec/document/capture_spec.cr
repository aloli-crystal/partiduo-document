# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Document::Api
private alias S = Document::SpecSupport

private def details(**values) : Api::DetailsInput
  Api::DetailsInput.new(**values)
end

describe "Justificatifs : dépôt et compléments (ADR-005 D8)" do
  it "conserve l'original tel quel et produit vignette et version réduite" do
    S.activate
    renderer = Document::Imaging.renderer.as(S::FakeRenderer)
    receipt = S.capture(S.jpeg, "IMG_0042.JPG")
    receipt.source.should eq("photo")
    receipt.status.should eq("to_process")
    receipt.content_type.should eq("image/jpeg")
    receipt.filename.should eq("IMG_0042.JPG")
    receipt.byte_size.should eq(S.jpeg.size)
    receipt.captured_by_id.should eq(1)
    renderer.calls.should eq([{"image/jpeg", Document::Imaging::PREVIEW_SIZE}, {"image/jpeg", Document::Imaging::THUMBNAIL_SIZE}])

    original = Api.file(S.admin, receipt.id)
    original.content.should eq(S.jpeg)
    original.content_type.should eq("image/jpeg")
    original.filename.should eq("IMG_0042.JPG")
    Partiduo::Api::Core.attachment(S.admin, receipt.original_attachment_id).sha256.should eq(receipt.sha256)

    preview = Api.file(S.admin, receipt.id, "preview")
    preview.content_type.should eq("image/jpeg")
    preview.filename.should eq("IMG_0042-preview.jpg")
    preview.content[4].should eq(Document::Imaging::PREVIEW_SIZE.to_u8!)
    thumbnail = Api.file(S.reader, receipt.id, "thumbnail")
    thumbnail.filename.should eq("IMG_0042-thumbnail.jpg")
    expect_raises(Partiduo::Api::NotFound) { Api.file(S.admin, receipt.id, "data") }
  end

  it "reconnaît le format au contenu, pas au nom : PDF → fichier, HEIC → photo convertie" do
    S.activate
    pdf = S.capture(S::PDF, "facture.jpg")
    pdf.content_type.should eq("application/pdf")
    pdf.source.should eq("file")
    pdf.pdf?.should be_true

    heic = S.capture(S::HEIC, "")
    heic.content_type.should eq("image/heic")
    heic.source.should eq("photo")
    heic.filename.should eq("justificatif.heic")
    heic.preview?.should be_true
    Api.file(S.admin, heic.id).content.should eq(S::HEIC)
    Api.file(S.admin, heic.id, "preview").content_type.should eq("image/jpeg")

    S.capture(S::PNG, "scan.png", source: "file").source.should eq("file")
  end

  it "garde le justificatif sans vignette quand l'outil de rendu échoue" do
    S.activate
    Document::Imaging.renderer = S::FailingRenderer.new
    receipt = S.capture(S::PDF, "facture.pdf")
    receipt.preview_attachment_id.should be_nil
    receipt.thumbnail_attachment_id.should be_nil
    receipt.preview?.should be_false
    expect_raises(Partiduo::Api::NotFound) { Api.file(S.admin, receipt.id, "thumbnail") }
    Api.file(S.admin, receipt.id).content.should eq(S::PDF)
  end

  it "refuse un fichier vide, trop gros ou d'un format non pris en charge" do
    S.activate
    result = Api.capture(S.admin, Api::CaptureInput.new("vide.png", Bytes.empty))
    result.error_keys.should eq(["document.errors.receipt.content.empty"])
    result = Api.capture(S.admin, Api::CaptureInput.new("page.html", "<html></html>".to_slice))
    result.error_keys.should eq(["document.errors.receipt.content.unsupported"])
    result = Api.capture(S.admin, Api::CaptureInput.new("texte.txt", "bonjour".to_slice))
    result.error_keys.should eq(["document.errors.receipt.content.unsupported"])
    big = Bytes.new(Api::MAX_BYTES + 1)
    big.copy_from(S::PDF)
    result = Api.capture(S.admin, Api::CaptureInput.new("gros.pdf", big))
    result.errors.first.key.should eq("document.errors.receipt.content.too_large")
    result.errors.first.params.should eq({"max" => "20"})
    result = Api.capture(S.admin, Api::CaptureInput.new("t.png", S::PNG, source: "scanner"))
    result.error_keys.should eq(["document.errors.receipt.source.invalid"])
    Document::Receipt.all.count.should eq(0)
  end

  it "enregistre les compléments facultatifs et reconnaît la fiche du fournisseur" do
    S.activate
    PartiduoUi::Reference.provision("fr")
    supplier = PartiduoUi::Books.card("SUPPLIER", "Orange Business", "FOUR-ORANGE")
    receipt = S.capture(details: details(supplier_code: "four-orange", amount: S.d("86.40"), date: S.date("2026-09-24"),
      kind: "invoice", note: "  fibre  ", reference: "FB-2026-0918-4471"))
    receipt.supplier_name.should eq("Orange Business")
    receipt.supplier_card_id.should eq(supplier.id)
    receipt.supplier_code.should eq("FOUR-ORANGE")
    receipt.amount.should eq(S.d("86.40"))
    receipt.date.should eq(S.date("2026-09-24"))
    receipt.kind.should eq("invoice")
    receipt.note.should eq("fibre")
    receipt.reference.should eq("FB-2026-0918-4471")

    free = S.capture(details: details(supplier_name: "Station Total Tours Nord", kind: "ticket"))
    free.supplier_card_id.should be_nil
    free.supplier_name.should eq("Station Total Tours Nord")
    S.capture.supplier_name.should eq("")
  end

  it "refuse des compléments incohérents, champ par champ" do
    S.activate
    result = Api.capture(S.admin, Api::CaptureInput.new("t.png", S::PNG, details: details(
      supplier_code: "INCONNU", amount: S.d("-1"), kind: "facture", currency_code: "euro", note: "x" * 2001,
      reference: "r" * 101, supplier_name: "n" * 256)))
    result.errors.map { |error| {error.field, error.key} }.sort!.should eq([
      {"amount", "document.errors.receipt.amount.negative"},
      {"currency_code", "document.errors.receipt.currency_code.invalid"},
      {"kind", "document.errors.receipt.kind.invalid"},
      {"note", "document.errors.receipt.note.too_long"},
      {"reference", "document.errors.receipt.reference.too_long"},
      {"supplier_code", "document.errors.receipt.supplier_code.unknown"},
      {"supplier_name", "document.errors.receipt.supplier_name.too_long"},
    ])
    Api.check_details(S.admin, details(amount: S.d("1.23456"))).error_keys.should eq(["document.errors.receipt.amount.too_precise"])
    Api.check_details(S.admin, details(amount: S.d("1.20000"), currency_code: "usd")).success?.should be_true
    Api.check_capture(S.admin, Api::CaptureInput.new("t.png", S::PNG)).success?.should be_true
    Document::Receipt.all.count.should eq(0)
  end

  it "modifie les compléments, écarte et remet à traiter" do
    S.activate
    receipt = S.capture
    updated = Api.update_details(S.admin, receipt.id, details(supplier_name: "Leroy Merlin", amount: S.d("37.90"))).value!
    updated.supplier_name.should eq("Leroy Merlin")
    updated.amount.should eq(S.d("37.90"))
    Api.update_details(S.admin, receipt.id, details(amount: S.d("-2"))).error_keys.should eq(["document.errors.receipt.amount.negative"])

    discarded = Api.discard(S.admin, receipt.id).value!
    discarded.status.should eq("discarded")
    discarded.discarded_at.should_not be_nil
    Api.discard(S.admin, receipt.id).error_keys.should eq(["document.errors.receipt.status.not_to_process"])
    Api.counts(S.reader).should eq(Api::CountsView.new(0, 0, 1))
    Api.pending_count(S.reader).should eq(0)

    Api.reopen(S.admin, receipt.id).value!.status.should eq("to_process")
    Api.reopen(S.admin, receipt.id).error_keys.should eq(["document.errors.receipt.status.already_to_process"])
    expect_raises(Partiduo::Api::NotFound) { Api.discard(S.admin, 999_999_i64) }
  end

  it "liste la boîte par statut, du plus récent au plus ancien, et cherche" do
    S.activate
    first = S.capture(details: details(supplier_name: "Orange", note: "fibre"))
    second = S.capture(details: details(supplier_name: "Bureau Vallée", reference: "2026-09-7731"))
    third = S.capture(S::PDF, "loyer-octobre.pdf")
    Api.discard(S.admin, third.id)
    Api.receipts(S.reader).map(&.id).should eq([second.id, first.id])
    Api.receipts(S.reader, Api::ReceiptQuery.new(status: "discarded")).map(&.id).should eq([third.id])
    Api.receipts(S.reader, Api::ReceiptQuery.new(status: nil)).size.should eq(3)
    Api.receipts(S.reader, Api::ReceiptQuery.new(search: "VALLÉE")).map(&.id).should eq([second.id])
    Api.receipts(S.reader, Api::ReceiptQuery.new(status: nil, search: "loyer")).map(&.id).should eq([third.id])
    Api.receipts(S.reader, Api::ReceiptQuery.new(search: "7731")).map(&.id).should eq([second.id])
    Api.receipts(S.reader, Api::ReceiptQuery.new(limit: 1, offset: 1)).map(&.id).should eq([first.id])
    Api.receipts(S.reader, Api::ReceiptQuery.new(source: "file", status: nil)).map(&.id).should eq([third.id])
    Api.count_receipts(S.reader).should eq(2)
    Api.counts(S.reader).should eq(Api::CountsView.new(2, 0, 1))
  end

  it "signale les doublons : même contenu, ou même fournisseur, date et montant (ADR-004 D9)" do
    S.activate
    same_day = details(supplier_name: "Station Total", amount: S.d("68.52"), date: S.date("2026-09-25"))
    first = S.capture(S.jpeg, "a.jpg", details: same_day)
    copy = S.capture(S.jpeg, "b.jpg")
    other = S.capture(S::PNG, "c.png", details: details(supplier_name: "station total", amount: S.d("68.52"), date: S.date("2026-09-25")))
    unrelated = S.capture(S::PDF, "d.pdf", details: details(supplier_name: "Station Total", amount: S.d("10"), date: S.date("2026-09-25")))
    Api.duplicates(S.reader, first.id).receipts.map(&.id).should eq([copy.id, other.id])
    Api.duplicates(S.reader, unrelated.id).found?.should be_false
    Api.discard(S.admin, copy.id)
    Api.duplicates(S.reader, first.id).receipts.map(&.id).should eq([other.id])
  end

  it "garantit en base les statuts et le rattachement" do
    S.activate
    receipt = S.capture
    expect_raises(Exception, /document_receipt_link_check/) do
      Marten::DB::Connection.default.open(&.exec("UPDATE document_receipt SET status = 'attached' WHERE id = $1", receipt.id))
    end
    expect_raises(Exception, /document_receipt_status_check/) do
      Marten::DB::Connection.default.open(&.exec("UPDATE document_receipt SET status = 'lost' WHERE id = $1", receipt.id))
    end
    # La pièce jointe citée ne peut plus être effacée du socle.
    Partiduo::Api::Core.delete_attachment(Partiduo::Api::Actor.system, receipt.original_attachment_id)
      .error_keys.should eq(["core.errors.attachment.in_use"])
  end
end
