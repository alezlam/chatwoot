# Applies WhatsApp's contact directory to a WhatsApp Web (baileys) inbox: address-book names, the names
# people set themselves, and which phone number sits behind a hidden "@lid" id (sent as "LI.<id>").
#
# Only contacts this inbox already has are touched; the address book never creates contacts. A name is
# only replaced while it is still a placeholder (blank, a phone number or an "LI." id), so names an
# agent typed are kept. A hidden-number contact is merged into the contact that has its phone number.
# A WhatsApp profile photo is imported only for contacts without an avatar, so uploaded ones are kept.
class Whatsapp::BaileysContactDirectoryService
  PLACEHOLDER_NAME = /\A(\+?\d+|LI\.\w+)\z/

  pattr_initialize [:inbox!, :entries!]

  def perform
    entries.each do |entry|
      contact = resolve_contact(entry)
      next unless contact

      rename(contact, entry)
      Avatar::AvatarFromUrlJob.perform_later(contact, entry[:avatar_url]) if entry[:avatar_url].present? && !contact.avatar.attached?
    end
  end

  private

  def resolve_contact(entry)
    phone_contact = contact_inboxes[phone_source_id(entry[:phone])]&.contact
    lid_contact = contact_inboxes[entry[:lid]]&.contact
    return phone_contact || lid_contact unless phone_contact && lid_contact && phone_contact.id != lid_contact.id

    ContactMergeAction.new(account: inbox.account, base_contact: phone_contact, mergee_contact: lid_contact).perform
  end

  def rename(contact, entry)
    attributes = { name: new_name(contact, entry), phone_number: new_phone_number(contact, entry[:phone]) }.compact
    contact.update!(attributes) if attributes.any?
  end

  def new_name(contact, entry)
    name = entry[:name].presence || entry[:push_name].presence
    name if name && placeholder_name?(contact)
  end

  def new_phone_number(contact, phone)
    "+#{phone}" if phone.present? && contact.phone_number.blank? && phone_number_free?(phone)
  end

  def placeholder_name?(contact)
    contact.name.blank? || contact.name.match?(PLACEHOLDER_NAME)
  end

  def phone_number_free?(phone)
    !inbox.account.contacts.exists?(phone_number: "+#{phone}")
  end

  # One query for the whole batch: the address book can hold thousands of entries.
  def contact_inboxes
    @contact_inboxes ||= begin
      source_ids = entries.flat_map { |entry| [phone_source_id(entry[:phone]), entry[:lid]] }.compact_blank.uniq
      inbox.contact_inboxes.where(source_id: source_ids).includes(:contact).index_by(&:source_id)
    end
  end

  def phone_source_id(phone)
    return if phone.blank?

    @phone_source_ids ||= {}
    @phone_source_ids[phone] ||= Whatsapp::PhoneNumberNormalizationService.new(inbox).normalize_and_find_contact_by_provider(phone, :cloud)
  end
end
