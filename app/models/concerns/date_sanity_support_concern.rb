# frozen_string_literal: true

module DateSanitySupportConcern
  extend ActiveSupport::Concern

  included do
    before_validation :init_dates
    validate :date_sanity
  end

  def init_dates
    self.start_date ||= course.start_date
    self.end_date ||= course.end_date
  end

  def date_sanity
    return if start_date.nil? || end_date.nil?

    if start_date.after? end_date
      errors.add( :start_date, "The start date of the #{model_name.human} must come before the end date" )
    end
    # Check if the dates are within the course
    unless start_date.nil? || end_date.nil?
      if start_date < course.start_date
        errors.add( :start_date,
                    "The #{model_name.human} cannot begin before the course has begun (#{course.start_date})" )
      end
      if end_date.change( sec: 0 ) > course.end_date.change( sec: 0 )
        msg = "The #{model_name.human} cannot continue after the course has ended"
        msg += "(#{end_date} > #{course.end_date})"
        errors.add( :end_date, msg )
      end
    end
    errors
  end
end
