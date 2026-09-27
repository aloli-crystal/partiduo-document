# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private def admin : Partiduo::Api::Actor
  Partiduo::Api::Actor.user(1_i64, [Partiduo::Api::Modules::MANAGE_MODULES])
end

private def menu_routes(entries : Array(Partiduo::Api::Modules::MenuView)) : Array(String?)
  entries.flat_map { |entry| [entry.route] + menu_routes(entry.children) }
end

describe "Extension DOCUMENT : manifeste et activation (ADR-003 D2, D4 ; ADR-005 D8)" do
  it "déclare une extension conforme au contrat du cœur" do
    manifest = Partiduo::Modules[Document::CODE]
    manifest.kind.should eq(Partiduo::Modules::Kind::Extension)
    manifest.version.should eq(Document::VERSION)
    manifest.permissions.should eq(["document.receipt.read", "document.receipt.write"])
    manifest.menus.map { |menu| {menu.code, menu.parent, menu.route, menu.permission} }
      .should eq([{"DOCUMENT_INBOX", "ENTRY", "document:index", "document.receipt.read"}])
    manifest.subscribed_events.sort.should eq(["entry.cancelled", "entry.posted"])
    manifest.uis.map(&.path).should eq(["ui/bulma"])
    manifest.depends_on.should be_empty
    Partiduo::Modules.structure_errors.should be_empty
    # Sur le socle seul (réception des factures électroniques, ADR-004 D9).
    Partiduo::Modules.dependency_errors(manifest, Set{Document::CODE}).should be_empty
  end

  it "traduit son nom, ses permissions et son menu en fr, en et nl" do
    manifest = Partiduo::Modules[Document::CODE]
    keys = [manifest.name] + manifest.permission_entries.map(&.label) + manifest.menus.map(&.label)
    Partiduo::LOCALES.each do |locale|
      I18n.with_locale(locale) do
        keys.each { |key| I18n.t(key).should_not contain("missing") }
      end
    end
  end

  it "est inactive tant que l'instance ne l'active pas" do
    viewer = Document::SpecSupport.reader
    Partiduo::Api::Modules.get(admin, "document").active.should be_false
    menu_routes(Partiduo::Api::Modules.menu(viewer)).should_not contain("document:index")
    expect_raises(Partiduo::Api::ModuleDisabled) { Document::Api.counts(viewer) }
    Document::Api.pending_count(viewer).should be_nil
  end

  it "s'active sur l'instance, se montre dans le menu « Saisie » et garde ses données désactivée" do
    Partiduo::Api::Modules.activate(admin, "document").value!.active.should be_true
    Partiduo::Modules.check!
    viewer = Document::SpecSupport.reader
    entry_menu = Partiduo::Api::Modules.menu(viewer).find! { |item| item.code == "ENTRY" }
    entry_menu.children.map(&.route).should contain("document:index")
    menu_routes(Partiduo::Api::Modules.menu(Partiduo::Api::Actor.user(3_i64, [] of String))).should_not contain("document:index")

    Document::SpecSupport.capture
    Document::Api.pending_count(viewer).should eq(1)

    Partiduo::Api::Modules.deactivate(admin, "document").value!.active.should be_false
    expect_raises(Partiduo::Api::ModuleDisabled) { Document::Api.receipts(viewer) }
    Document::Receipt.all.count.should eq(1)
    Partiduo::Api::Modules.activate(admin, "document")
    Document::Api.receipts(viewer).size.should eq(1)
  end

  it "s'active sans la Comptabilité ni la Facturation" do
    with_active_modules("") do
      Partiduo::Api::Modules.activate(admin, "document").success?.should be_true
      Document::SpecSupport.capture.status.should eq("to_process")
    end
  end

  it "refuse son contrat sans les permissions" do
    Document::SpecSupport.activate
    nobody = Partiduo::Api::Actor.user(3_i64, [] of String)
    expect_raises(Partiduo::Api::Forbidden) { Document::Api.receipts(nobody) }
    expect_raises(Partiduo::Api::Forbidden) { Document::Api.receipts(Partiduo::Api::Actor.anonymous) }
    # Déposer exige aussi la permission des pièces jointes du socle.
    writer = Partiduo::Api::Actor.user(4_i64, [Document::Api::READ, Document::Api::WRITE])
    expect_raises(Partiduo::Api::Forbidden) do
      Document::Api.capture(writer, Document::Api::CaptureInput.new("t.png", Document::SpecSupport::PNG))
    end
    # Lire la boîte ne donne pas accès aux fichiers sans `core.attachment.read`.
    receipt = Document::SpecSupport.capture
    lister = Partiduo::Api::Actor.user(5_i64, [Document::Api::READ])
    Document::Api.receipt(lister, receipt.id).id.should eq(receipt.id)
    expect_raises(Partiduo::Api::Forbidden) { Document::Api.file(lister, receipt.id) }
    Document::Api.pending_count(lister).should eq(1)
    Document::Api.pending_count(nobody).should be_nil
  end
end
