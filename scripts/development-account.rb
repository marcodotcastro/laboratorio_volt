# frozen_string_literal: true

# Creates the deterministic local account consumed by the All In One and Imob
# development login helpers.  This runs inside the CRM container, so it uses
# the same database and Rails environment as the development API.
email = ENV.fetch('VDD_DEVELOPMENT_ACCOUNT_EMAIL', 'vdd@local.test')
password = DevelopmentAccounts.default_password
now = Time.current

Company.transaction do
  company = Company.find_by(id: 1)

  unless company
    Company.insert!({
      id: 1,
      name: 'VDD Local Development',
      slug: 'vdd-local-development',
      origin_source: 'vdd',
      company_type: 'imobiliaria',
      active: true,
      test: true,
      waiting: false,
      c2s_integration: false,
      created_at: now,
      updated_at: now
    })
    Company.connection.reset_pk_sequence!('companies')
    company = Company.find(1)
  end

  user = company.users.find_or_initialize_by(email: email)
  user.assign_attributes(
    first_name: 'VDD',
    last_name: 'Developer',
    status: :active,
    role: :admin,
    password: password,
    password_confirmation: password
  )
  user.save!

  puts "Development account ready: #{email} (company_id=#{company.id})"
end
