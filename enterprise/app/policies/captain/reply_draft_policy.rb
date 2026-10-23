class Captain::ReplyDraftPolicy < ApplicationPolicy
  def index?
    true
  end

  def destroy?
    true
  end

  def send_reply?
    true
  end
end
