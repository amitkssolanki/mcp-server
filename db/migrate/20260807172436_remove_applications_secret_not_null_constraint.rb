# frozen_string_literal: true

class RemoveApplicationsSecretNotNullConstraint < ActiveRecord::Migration[8.1]
  def change
    change_column_null :oauth_applications, :secret, true
  end
end
