# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Document::Api
private alias S = Document::SpecSupport

private def invoice(ref : String = "superpdp:4471", content : Bytes = S::PDF, data : Bytes? = S::XML,
                    details : Api::DetailsInput = Api::DetailsInput.new(supplier_name: "Orange Business",
                      amount: S.d("86.40"), date: S.date("2026-09-24"), reference: "FB-2026-0918-4471")) : Api::ReceiveInput
  Api::ReceiveInput.new(filename: "FB-2026-0918-4471.pdf", content: content, external_ref: ref, details: details,
    data_filename: "FB-2026-0918-4471.xml", data: data)
end

describe "Justificatifs : factures reçues par la plateforme agréée (API publique, ADR-004 D9)" do
  it "fait entrer la facture dans la même boîte, avec ses données structurées" do
    S.activate
    receipt = Api.receive(Partiduo::Api::Actor.system, invoice).value!
    receipt.source.should eq("einvoice")
    receipt.status.should eq("to_process")
    receipt.kind.should eq("invoice")
    receipt.external_ref.should eq("superpdp:4471")
    receipt.supplier_name.should eq("Orange Business")
    receipt.reference.should eq("FB-2026-0918-4471")
    receipt.captured_by_id.should be_nil
    data = Api.file(S.admin, receipt.id, "data")
    data.content.should eq(S::XML)
    data.content_type.should eq("application/xml")
    data.filename.should eq("FB-2026-0918-4471.xml")
    Api.pending_count(S.reader).should eq(1)
    Api.receipts(S.reader, Api::ReceiptQuery.new(source: "einvoice")).map(&.id).should eq([receipt.id])
  end

  it "est idempotente : une facture déjà reçue n'est pas dupliquée" do
    S.activate
    first = Api.receive(Partiduo::Api::Actor.system, invoice).value!
    again = Api.receive(Partiduo::Api::Actor.system, invoice).value!
    again.id.should eq(first.id)
    Document::Receipt.all.count.should eq(1)
  end

  it "admet le XML seul quand la plateforme ne fournit pas de rendu lisible" do
    S.activate
    receipt = Api.receive(Partiduo::Api::Actor.system, invoice("pa:1", content: S::XML, data: nil)).value!
    receipt.content_type.should eq("application/xml")
    receipt.preview?.should be_false
    receipt.data_attachment_id.should be_nil
  end

  it "refuse une facture sans identifiant, de format inconnu ou aux données illisibles" do
    S.activate
    Api.receive(Partiduo::Api::Actor.system, invoice("  ")).error_keys.should eq(["document.errors.receipt.external_ref.blank"])
    Api.receive(Partiduo::Api::Actor.system, invoice("pa:2", content: "bonjour".to_slice))
      .error_keys.should eq(["document.errors.receipt.content.unsupported"])
    result = Api.receive(Partiduo::Api::Actor.system, invoice("pa:3", data: S::PDF))
    result.errors.map(&.field).should eq(["data"])
    Document::Receipt.all.count.should eq(0)
  end

  it "exige la permission d'écrire et l'extension active" do
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.receive(Partiduo::Api::Actor.system, invoice) }
    S.activate
    expect_raises(Partiduo::Api::Forbidden) { Api.receive(S.reader, invoice) }
  end
end
