# frozen_string_literal: true

require 'faker'
class Project < ApplicationRecord
  include DateSanitySupportConcern
  include TimezonesSupportConcern
  after_save :build_assessment

  belongs_to :course, inverse_of: :projects
  has_many :rosters, through: :course
  belongs_to :style, inverse_of: :projects
  belongs_to :factor_pack, inverse_of: :projects, optional: true
  has_many :groups, inverse_of: :project, dependent: :destroy
  has_many :bingo_games, inverse_of: :project, dependent: :destroy
  has_many :assessments, inverse_of: :project, dependent: :destroy
  has_many :installments, through: :assessments, dependent: :destroy

  has_many :users, through: :groups
  has_many :factors, through: :factor_pack

  delegate :timezone, :name, :anon_offset, to: :course, prefix: true

  validates :name, :end_dow, :start_dow, presence: true
  validates :end_date, :start_date, presence: true
  before_create :anonymize

  validates :start_dow, :end_dow, numericality: {
    greater_than_or_equal_to: 0,
    less_than_or_equal_to: 6
  }

  # Business rule validation checks
  validate :activation_status

  # Set default values
  after_initialize do
    if new_record?
      self.active = false
      # AECT 2023 factor pack is the default
      self.factor_pack_id ||= 4
      # Sliders style
      self.style_id ||= 2
      self.start_dow ||= 5
      self.end_dow ||= 1

    end
  end

  def group_for_user( user )
    if -1 == id # This hack supports demonstration of group term lists
      Group.new( name: 'SuperStars', users: [user] )
    else
      groups.joins( :users ).find_by( users: { id: user.id } )
    end
  end

  def get_performance( user )
    installments_count = installments.where( user: ).count
    assessments.count.zero? ? 100 : 100 * installments_count / assessments.count
  end

  # TODO: Not ideal structuring for UI
  def get_link
    # helpers = Rails.application.routes.url_helpers
    # helpers.project_path self
    'project'
  end

  def get_user_appearance_counts
    Project.get_occurence_count_hash users
  end

  def get_group_appearance_counts
    Project.get_occurence_count_hash groups
  end

  def get_name( anonymous )
    anonymous ? anon_name : name
  end

  def self.get_occurence_count_hash( input_array )
    dup_hash = Hash.new( 0 )
    input_array.each { | v | dup_hash.store( v.id, dup_hash[v.id] + 1 ) }
    dup_hash
  end

  # If the date range wraps from Saturday to Sunday, it's not inside.
  def has_inside_date_range?
    has_inside_date_range = false
    has_inside_date_range = true if start_dow <= end_dow
    has_inside_date_range
  end

  # Check if the assessment is active, if we're in the date range and
  # within the day range.
  def is_available?
    tz = ActiveSupport::TimeZone.new( course.timezone )
    is_available = false
    init_date = tz.parse( DateTime.current.to_s )
    init_day = init_date.wday

    if active &&
       start_date <= init_date && end_date >= init_date
      if has_inside_date_range?
        is_available = true if start_dow <= init_day && end_dow >= init_day
      else

        is_available = true unless init_day < start_dow && end_dow < init_day
      end
    end
    is_available
  end

  def type
    'Project'
  end

  def status_for_user( _user )
    # get some sort of count of completion rates
    'Coming soon'
  end

  def status
    'Coming soon'
  end

  def get_days_applicable
    days = []
    if has_inside_date_range?
      start_dow.upto end_dow do | day_num |
        days << day_num
      end
    else
      start_dow.upto 6 do | day_num |
        days << day_num
      end
      0.upto end_dow do | day_num |
        days << day_num
      end
    end
    days
  end

  def get_events( user: )
    helpers = Rails.application.routes.url_helpers
    events = []
    user_role = course.get_user_role( user )

    edit_url = nil
    destroy_url = nil
    if 'instructor' == user_role
      edit_url = helpers.edit_project_path( self )
      destroy_url = helpers.project_path( self )
    end

    if ( active && 'enrolled_student' == user_role ) ||
       ( 'instructor' == user_role )

      days = get_days_applicable

      events << {
        title: "#{name} assessment",
        id: "asmt_#{id}",
        allDay: true,
        start: start_date,
        end: end_date,
        backgroundColor: '#FF9999',
        edit_url:,
        destroy_url:,

        startTime: '00:00',
        endTime: { day: days.size },
        daysOfWeek: [days[0]],
        startRecur: start_date,
        endRecur: end_date
      }
    end

    events
  end

  private

  # Validation check code

  def activation_status
    if active_before_last_save && active &&
       ( start_dow_changed? || end_dow_changed? ||
        start_date_changed? || end_date_changed? ||
        factor_pack_id_changed? || style_id_changed? )
      self.active = false
    elsif !active_before_last_save && active

      get_user_appearance_counts.each do | user_id, count |
        # Check the users
        user = User.find( user_id )
        if Roster.enrolled.where( user:, course: ).count < 1
          errors.add( :active, "#{user.name false} does not appear to be enrolled in this course." )
        elsif count > 1
          errors.add( :active, "#{user.name false} appears #{count} times in your project." )
        end
      end
      # Check the groups
      get_group_appearance_counts.each do | group_id, count |
        if count > 1
          group = Group.find( group_id )
          errors.add( :active, "#{group.name false} (group) appears #{count} times in your project." )
        end
      end
      errors.add( :factor_pack, 'Factor Pack must be set before a project can be activated' ) if factor_pack.nil?
      # If this is an activation, we need to set up any necessary weeklies
      Assessment.configure_current_assessment self
    end
    errors
  end

  # Handler for building an assessment, if necessary
  def build_assessment
    # Nothing needs to be done unless we're active
    Assessment.configure_current_assessment self if active?
  end

  def anonymize
    locations = [
      Faker::Games::Pokemon,
      Faker::Games::Touhou,
      Faker::Games::Overwatch,
      Faker::Movies::HowToTrainYourDragon,
      Faker::Fantasy::Tolkien
    ]
    self.anon_name = "#{locations.sample.location} #{Faker::Job.field}"
  end
end
