# frozen_string_literal: true

# Redmine plugin for Document Management System "Features"
#
# Karel Pičman <karel.picman@kontron.com>
#
# This file is part of Redmine DMSF plugin.
#
# Redmine DMSF plugin is free software: you can redistribute it and/or modify it under the terms of the GNU General
# Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any
# later version.
#
# Redmine DMSF plugin is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
# the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
# more details.
#
# You should have received a copy of the GNU General Public License along with Redmine DMSF plugin. If not, see
# <https://www.gnu.org/licenses/>.

require File.expand_path('../../test_helper', __FILE__)

# Workflow step actions tests
class DmsfWorkflowStepActionTest < RedmineDmsf::Test::UnitTest
  include Redmine::I18n

  fixtures :dmsf_workflow_steps, :dmsf_workflow_step_actions, :dmsf_folders, :dmsf_files,
           :dmsf_file_revisions

  def setup
    @wfsac1 = DmsfWorkflowStepAction.find 1
    @wfsac2 = DmsfWorkflowStepAction.find 2
    @wfsac3 = DmsfWorkflowStepAction.find 3
  end

  def test_create
    wfsac = DmsfWorkflowStepAction.new
    wfsac.dmsf_workflow_step_assignment_id = 1
    wfsac.action = DmsfWorkflowStepAction::ACTION_DELEGATE
    wfsac.note = 'Approval'
    assert wfsac.save, wfsac.errors.full_messages.to_sentence
    wfsac.reload
    assert wfsac.created_at
  end

  def test_update
    @wfsac1.dmsf_workflow_step_assignment_id = 2
    @wfsac1.action = DmsfWorkflowStepAction::ACTION_REJECT
    @wfsac1.note = 'Rejection'
    assert @wfsac1.save, !@wfsac1.errors.full_messages.to_sentence
    @wfsac1.reload
    assert_equal 2, @wfsac1.dmsf_workflow_step_assignment_id
    assert_equal DmsfWorkflowStepAction::ACTION_REJECT, @wfsac1.action
    assert_equal 'Rejection', @wfsac1.note
  end

  def test_validate_action_presence
    @wfsac1.action = nil
    assert_not @wfsac1.save
    assert_equal 1, @wfsac1.errors.count
  end

  def test_validate_note
    @wfsac1.note = ''
    @wfsac1.action = DmsfWorkflowStepAction::ACTION_REJECT
    assert_not @wfsac1.save
    assert_equal 1, @wfsac1.errors.count
    @wfsac1.note = 'Rejected because....'
    assert @wfsac1.save
    @wfsac1.action = DmsfWorkflowStepAction::ACTION_DELEGATE
    @wfsac1.note = ''
    assert_not @wfsac1.save
    assert_equal 1, @wfsac1.errors.count
    @wfsac1.note = 'Delegated because'
    assert @wfsac1.save, @wfsac1.errors.full_messages.to_sentence
    @wfsac1.note = ''
    @wfsac1.action = DmsfWorkflowStepAction::ACTION_APPROVE
    assert @wfsac1.save, @wfsac1.errors.full_messages.to_sentence
  end

  def test_validate_dmsf_workflow_step_assignment_id_uniqueness
    @wfsac2.dmsf_workflow_step_assignment_id = @wfsac1.dmsf_workflow_step_assignment_id
    @wfsac2.action = @wfsac1.action
    assert_not @wfsac2.save
    assert_equal 1, @wfsac2.errors.count
    @wfsac1.action = DmsfWorkflowStepAction::ACTION_REJECT
    @wfsac2.action = @wfsac1.action
    assert @wfsac1.save, @wfsac1.errors.full_messages.to_sentence
    assert_not @wfsac2.save
    assert_equal 1, @wfsac2.errors.count
    @wfsac1.action = DmsfWorkflowStepAction::ACTION_DELEGATE
    assert @wfsac1.save
    @wfsac2.action = @wfsac1.action
    assert @wfsac2.save
  end

  def test_destroy
    @wfsac1.destroy
    assert_nil DmsfWorkflowStepAction.find_by(id: 1)
  end

  def test_is_finished
    @wfsac1.action = DmsfWorkflowStepAction::ACTION_APPROVE
    assert @wfsac1.finished?
    @wfsac1.action = DmsfWorkflowStepAction::ACTION_REJECT
    assert @wfsac1.finished?
    @wfsac1.action = DmsfWorkflowStepAction::ACTION_DELEGATE
    assert_not @wfsac1.finished?
  end

  def test_action_str
    assert_equal DmsfWorkflowStepAction.action_str(DmsfWorkflowStepAction::ACTION_APPROVE), l(:title_approval)
    assert_equal DmsfWorkflowStepAction.action_str(DmsfWorkflowStepAction::ACTION_REJECT), l(:title_rejection)
    assert_equal DmsfWorkflowStepAction.action_str(DmsfWorkflowStepAction::ACTION_DELEGATE), l(:title_delegation)
    assert_equal DmsfWorkflowStepAction.action_str(DmsfWorkflowStepAction::ACTION_ASSIGN), l(:title_assignment)
    assert_equal DmsfWorkflowStepAction.action_str(DmsfWorkflowStepAction::ACTION_START), l(:title_start)
  end
end
