# frozen_string_literal: true

require 'faker'
class Course < ApplicationRecord
  belongs_to :school, inverse_of: :courses, counter_cache: true
  has_many :projects, inverse_of: :course, dependent: :destroy, autosave: true
  has_many :rosters, inverse_of: :course, dependent: :destroy, autosave: true
  has_many :bingo_games, inverse_of: :course, dependent: :destroy, autosave: true
  has_many :candidate_lists, through: :bingo_games
  has_many :concepts, through: :candidate_lists
  has_many :users, through: :rosters
  belongs_to :consent_form, counter_cache: true, inverse_of: :courses, optional: true
  has_many :assignments, inverse_of: :course, autosave: true, dependent: :destroy

  has_many :experiences, inverse_of: :course, dependent: :destroy, autosave: true

  delegate :active, to: :consent_form, prefix: true

  validates :timezone, :start_date, :end_date, presence: true
  validates :name, presence: true
  validate :date_sanity
  validate :activity_date_check

  before_validation :timezone_adjust_comprehensive
  before_create :anonymize

  def pretty_name( anonymous = false )
    if anonymous
      "#{anon_name} (#{anon_number})"
    elsif number.present?
      "#{name} (#{number})"
    else
      name
    end
  end

  def get_activities
    activities = projects.to_a
    activities.concat bingo_games
    activities.concat experiences
    activities.concat assignments

    activities.sort_by( &:end_date )
  end

  def get_consent_log( user: )
    log = nil

    unless consent_form_id.nil? || !consent_form.is_active?
      log = consent_form.consent_logs
                        .find_by( user: )
      if log.nil?
        log = user.consent_logs.create(
          consent_form_id:,
          presented: false
        )
      end
    end
    log
  end

  def get_name( anonymous = false )
    anonymous ? anon_name : name
  end

  def get_number( anonymous = false )
    anonymous ? anon_number : number
  end

  def set_user_role( user, role )
    roster = rosters.find_by( user: )
    roster = Roster.new( user:, course: self ) if roster.nil?
    roster.role = role
    roster.save
    logger.debug roster.errors.full_messages unless roster.errors.empty?
  end

  def drop_student( user )
    roster = Roster.find_by( user:, course: self )
    roster.role = Roster.roles[:dropped_student]
    roster.save
  end

  def get_user_role( user )
    roster = rosters.find_by( user: )
    roster&.role
  end

  def copy_from_template( new_start: )
    # Timezone checking here
    # course_tz = ActiveSupport::TimeZone.new(timezone || 'UTC')
    # new_start = new_start.getlocal(course_tz.utc_offset).beginning_of_day
    # new_start = new_start.beginning_of_day.getlocal(course_tz)
    # new_start = course_tz.utc_to_local(new_start).beginning_of_day
    # date_difference = new_start - course_tz.local(d.year, d.month, d.day).beginning_of_day
    # date_difference = (new_start - start_date + course_tz.utc_offset) / 86_400
    date_difference = ( new_start - start_date.beginning_of_day ) / 86_400
    new_course = nil

    Course.transaction do
      # create the course

      new_course = school.courses.new(
        name: "Copy of #{name}",
        number: "Copy of #{number}",
        description:,
        timezone:,
        start_date: start_date.advance( days: date_difference ),
        end_date: end_date.advance( days: date_difference )
      )

      # copy the faculty rosters
      rosters.faculty.each do | roster |
        new_obj = new_course.rosters.new(
          role: roster.role,
          user: roster.user
        )
        new_obj.save!
      end

      # copy the projects
      proj_hash = {}
      course_tz = ActiveSupport::TimeZone.new( timezone )
      offset = course_tz.utc_offset

      projects.each do | project |
        new_obj = new_course.projects.new(
          name: project.name,
          style: project.style,
          factor_pack: project.factor_pack,
          start_date: project.start_date.advance( days: date_difference ),
          end_date: project.end_date
                           .advance( seconds: offset )
                           .advance( days: date_difference ),
          start_dow: project.start_dow,
          end_dow: project.end_dow
        )
        new_obj.save!
        proj_hash[project] = new_obj
      end

      # copy the experiences
      experiences.each do | experience |
        new_obj = new_course.experiences.new(
          name: experience.name,
          start_date: experience.start_date.advance( days: date_difference ),
          end_date: experience.end_date
                              .advance( seconds: offset )
                              .advance( days: date_difference )
        )
        new_obj.save!
      end

      # copy the bingo! games
      bingo_games.each do | bingo_game |
        new_obj = new_course.bingo_games.new(
          topic: bingo_game.topic,
          description: bingo_game.description,
          link: bingo_game.link,
          source: bingo_game.source,
          group_option: bingo_game.group_option,
          individual_count: bingo_game.individual_count,
          lead_time: bingo_game.lead_time,
          group_discount: bingo_game.group_discount,
          project: proj_hash[bingo_game.project],
          start_date: bingo_game.start_date.advance( days: date_difference ),
          end_date: bingo_game.end_date
                              .advance( seconds: offset )
                              .advance( days: date_difference )
        )
        new_obj.save!
      end

      # copy the assignments
      assignments.each do | assignment |
        new_obj = new_course.assignments.new(
          name: assignment.name,
          description: assignment.description,
          start_date: assignment.start_date.advance( days: date_difference ),
          end_date: assignment.end_date
                              .advance( seconds: offset )
                              .advance( days: date_difference ),
          rubric: assignment.rubric,
          file_sub: assignment.file_sub,
          link_sub: assignment.link_sub,
          text_sub: assignment.text_sub,
          passing: assignment.passing,
          group_enabled: assignment.group_enabled,
          project: proj_hash[assignment.project]
        )

        new_obj.save!
      end

      new_course.save!
    end
    new_course
  end

  def diversity_analysis( member_count: 4 )
    students = rosters.enrolled.collect( &:user )
    combinations = students.combination( member_count ).size
    max_actual = 1000
    results = {
      student_count: students.size,
      combinations:,
      actual: max_actual >= combinations
    }

    options = []
    if results[:actual]
      students.combination( member_count ).each do | members |
        group_score = Group.calc_diversity_score_for_group( users: members )
        options << group_score
      end
    else
      max_actual.times do
        members = students.sample member_count
        group_score = Group.calc_diversity_score_for_group( users: members )
        options << group_score
      end
    end
    options = options.reject { | n | n < 1 }.sort

    results[:min] = options.first
    results[:max] = options.last
    results[:average] = options.inject { | sum, el | sum + el } / options.size.to_f
    results[:class_score] = Group.calc_diversity_score_for_group( users: students )

    results
  end

  def add_user_by_email( user_email, instructor = false )
    ret_val = false

    if EmailAddress.valid? user_email
      role = instructor ? Roster.roles[:instructor] : Roster.roles[:invited_student]
      # Searching for the student and:
      user = User.joins( :emails ).find_by( emails: { email: user_email } )

      passwd = SecureRandom.alphanumeric( 10 ) # creates a password

      if user.nil?
        user = User.create( email: user_email, admin: false, timezone:, password: passwd, school: )
        logger.debug user.errors.full_messages unless user.errors.empty?
      end

      unless user.nil?
        existing_roster = Roster.find_by( course: self, user: )
        if existing_roster.nil?
          Roster.create( user:, course: self, role: )
          ret_val = true
        elsif instructor || existing_roster.enrolled_student!
          existing_roster.role = role
          existing_roster.save
          if existing_roster.errors.empty?
            ret_val = true
          else
            logger.debug existing_roster.errors.full_messages
          end
        end
        # TODO: Let's add course invitation emails here in the future
      end
    end
    ret_val
  end

  def add_students_by_email( student_emails )
    count = 0
    student_emails.split( /[\s,]+/ ).each do | email |
      count += 1 if add_user_by_email email
    end
    count
  end

  def add_instructors_by_email( instructor_emails )
    count = 0
    instructor_emails.split( /[\s,]+/ ).each do | email |
      count += 1 if add_user_by_email( email, true )
    end
    count
  end

  def enrolled_students
    rosters.includes( user: [:emails] ).enrolled.collect( &:user )
  end

  def instructors
    rosters.instructor.collect( &:user )
  end

  private

  # Validation check code
  def date_sanity
    if start_date.blank? || end_date.blank?
      errors.add( :start_dow, 'The start date is required' ) if start_date.blank?
      errors.add( :end_dow, 'The end date is required' ) if end_date.blank?
    elsif start_date > end_date
      errors.add( :start_dow, 'The start date must come before the end date' )
    end
    errors
  end

  # TODO: - check for date sanity of experiences and projects
  def activity_date_check
    experiences.reload.each do | experience |
      if experience.start_date < start_date
        errors[:start_date].presence || ''
        msg = "Experience '#{experience.name}' currently starts before this course does"
        msg += " (#{experience.start_date} < #{start_date})."
        errors.add( :start_date, msg )
      end
      next unless experience.end_date.change( sec: 0 ) > end_date

      errors[:end_date].presence || ''
      msg = "Experience '#{experience.name}' currently ends after this course does"
      msg += " (#{experience.end_date} > #{end_date})."
      errors.add( :end_date, msg )
    end
    projects.reload.each do | project |
      if project.start_date < start_date
        msg = errors[:start_date].presence || ''
        msg += "Project '#{project.name}' currently starts before this course does"
        msg += " (#{project.start_date} < #{start_date})."
        errors.add( :start_date, msg )
      end
      next unless project.end_date.change( sec: 0 ) > end_date

      errors[:end_date].presence || ''
      msg = "Project '#{project.name}' currently ends after this course does"
      msg += " (#{project.end_date} > #{end_date})."
      errors.add( :end_date, msg )
    end
    bingo_games.reload.each do | bingo_game |
      if bingo_game.start_date < start_date
        errors[:start_date].presence || ''
        msg = "Bingo! '#{bingo_game.topic}' currently starts before this course does "
        msg += " (#{bingo_game.start_date} < #{start_date})."
        errors.add( :start_date, msg )
      end
      next unless bingo_game.end_date.change( sec: 0 ) > end_date

      errors[:end_date].presence || ''
      msg = "Bingo! '#{bingo_game.topic}' currently ends after this course does "
      msg += " (#{bingo_game.end_date} > #{end_date})."
      errors.add( :end_date, msg )
    end
  end

  def anonymize
    levels = %w[Beginning Intermediate Advanced]
    self.anon_name = "#{levels.sample} #{Faker::Company.industry}"
    dpts = %w[BUS MED ENG RTG MSM LEH EDP
              GEO IST MAT YOW GFB RSV CSV MBV]
    self.anon_number = "#{dpts.sample}-#{rand( 100..700 )}"
    # Data offset in days
    self.anon_offset = - Random.rand( 1000 ).days.to_i + 35
  end

  def timezone_adjust_comprehensive
    course_tz = ActiveSupport::TimeZone.new( timezone || 'UTC' )
    # TODO: must handle changing timezones at some point

    # TZ corrections
    if ( start_date_changed? || timezone_changed? ) && start_date.present?
      d = start_date.utc
      new_date = course_tz.local( d.year, d.month, d.day ).beginning_of_day
      self.start_date = new_date
    end

    if ( end_date_changed? || timezone_changed? ) && end_date.present?
      d = end_date.in_time_zone( course_tz )
      new_date = course_tz.local( d.year, d.month, d.day ).end_of_day
      self.end_date = new_date.end_of_day.change( sec: 0 )
    end

    return unless timezone_changed? && timezone_was.present?

    orig_tz = ActiveSupport::TimeZone.new( timezone_was )

    Course.transaction do
      get_activities.each do | activity |
        d = orig_tz.parse( activity.start_date.to_s )
        d = course_tz.local( d.year, d.month, d.day )
        activity.start_date = d.beginning_of_day

        d = orig_tz.parse( activity.end_date.to_s )
        d = course_tz.local( d.year, d.month, d.day )
        activity.end_date = d.end_of_day
        activity.save!( validate: false )
      end
    end
  end
end
