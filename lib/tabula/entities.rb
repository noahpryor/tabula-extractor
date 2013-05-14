module Tabula

  class ZoneEntity
    attr_accessor :top, :left, :width, :height

    attr_accessor :texts

    def initialize(top, left, width, height)
      self.top = top
      self.left = left
      self.width = width
      self.height = height
      self.texts = []
    end

    def bottom
      self.top + self.height
    end

    def right
      self.left + self.width
    end

    # [x, y]
    def midpoint
      [self.left + (self.width / 2), self.top + (self.height / 2)]
    end

    def area
      self.width * self.height
    end

    def merge!(other)
      self.top    = [self.top, other.top].min
      self.left   = [self.left, other.left].min
      self.width  = [self.right, other.right].max - left
      self.height = [self.bottom, other.bottom].max - top
    end

    def horizontal_distance(other)
      (other.left - self.right).abs
    end

    def vertical_distance(other)
      (other.bottom - self.bottom).abs
    end

    # Roughly, detects if self and other belong to the same line
    def vertically_overlaps?(other)
      vertical_overlap = [0, [self.bottom, other.bottom].min - [self.top, other.top].max].max
      vertical_overlap > 0
    end

    # detects if self and other belong to the same column
    def horizontally_overlaps?(other)
      horizontal_overlap = [0, [self.right, other.right].min  - [self.left, other.left].max].max
      horizontal_overlap > 0
    end

    def overlaps?(other, ratio_tolerance=0.00001)
      self.overlap_ratio(other) > ratio_tolerance
    end

    def overlap_ratio(other)
      intersection_width = [0, [self.right, other.right].min  - [self.left, other.left].max].max
      intersection_height = [0, [self.bottom, other.bottom].min - [self.top, other.top].max].max
      intersection_area = [0, intersection_height * intersection_width].max

      union_area = self.area + other.area - intersection_area
      intersection_area / union_area
    end

    def to_h
      hash = {}
      [:top, :left, :width, :height].each do |m|
        hash[m] = self.send(m)
      end
      hash
    end

    def to_json(options={})
      self.to_h.to_json
    end
  end

  class Page < ZoneEntity
    attr_reader :rotation, :number

    def initialize(width, height, rotation, number, texts=[])
      super(0, 0, width, height)
      @rotation = rotation
      @number = number
      self.texts = texts
    end

    # get text, optionally from a provided area in the page [top, left, bottom, right]
    def get_text(area=nil)
      area = [0, 0, width, height] if area.nil?
      ze = ZoneEntity.new(area[0], area[1], area[3] - area[1], area[2] - area[0])
      self.texts.select { |t| t.overlaps? ze }
    end

    def to_json(options={})
      { :width => self.width,
        :height => self.height,
        :number => self.number,
        :rotation => self.rotation,
        :texts => self.texts
      }.to_json(options)
    end

  end

  class TextElement < ZoneEntity
    attr_accessor :font, :font_size, :text

    CHARACTER_DISTANCE_THRESHOLD = 1.5

    def initialize(top, left, width, height, font, font_size, text)
      super(top, left, width, height)
      self.font = font
      self.font_size = font_size
      self.text = text
    end

    # more or less returns True if distance < tolerance
    def should_merge?(other)
      raise TypeError, "argument is not a TextElement" unless other.instance_of?(TextElement)
      overlaps = self.vertically_overlaps?(other)

      tolerance = ((self.font_size + other.font_size) / 2) * 0.25

      overlaps or
        (self.height == 0 and other.height != 0) or
        (other.height == 0 and self.height != 0) and
        self.horizontal_distance(other) < tolerance
    end

    # more or less returns True if (tolerance <= distance < CHARACTER_DISTANCE_THRESHOLD*tolerance)
    def should_add_space?(other)
      raise TypeError, "argument is not a TextElement" unless other.instance_of?(TextElement)
      overlaps = self.vertically_overlaps?(other)

      tolerance = ((self.font_size + other.font_size) / 2) * 0.25

      dist = self.horizontal_distance(other)
      overlaps or
        (self.height == 0 and other.height != 0) or
        (other.height == 0 and self.height != 0) and
        ((tolerance <= dist) and (dist < tolerance*CHARACTER_DISTANCE_THRESHOLD))
    end

    def merge!(other)
      raise TypeError, "argument is not a TextElement" unless other.instance_of?(TextElement)
      # unless self.horizontally_overlaps?(other) or self.vertically_overlaps?(other)
      #   raise ArgumentError, "won't merge TextElements that don't overlap"
      # end
      if self.horizontally_overlaps?(other) and other.top < self.top
        self.text = other.text + self.text
      else
        self.text << other.text
      end
      super(other)
    end

    def to_h
      hash = super
      [:font, :text].each do |m|
        hash[m] = self.send(m)
      end
      hash
    end
  end


  class Line < ZoneEntity
    attr_accessor :text_elements

    def initialize
      self.text_elements = []
    end

    def <<(t)
      if self.text_elements.size == 0
        self.text_elements << t
        self.top = t.top
        self.left = t.left
        self.width = t.width
        self.height = t.height
      else
        if in_same_column = self.text_elements.find { |te| te.horizontally_overlaps?(t) }
          in_same_column.merge!(t)
        else
          self.text_elements << t
          self.merge!(t)
        end
      end
    end


  end

  class Column < ZoneEntity
    attr_accessor :text_elements

    def initialize(left, width, text_elements=[])
      super(0, left, width, 0)
      @text_elements = text_elements
    end

    def <<(te)
      self.text_elements << te
      self.update_boundaries!(te)
      self.text_elements.sort_by! { |t| t.top }
    end

    def update_boundaries!(text_element)
      self.merge!(text_element)
    end

    # this column can be merged with other_column?
    def contains?(other_column)
      self.horizontally_overlaps?(other_column)
    end

    def average_line_distance
      # avg distance between lines
      # this might help to MERGE lines that are shouldn't be split
      # e.g. cells with > 1 lines of text
      1.upto(self.text_elements.size - 1).map { |i|
        self.text_elements[i].top - self.text_elements[i - 1].top
      }.inject{ |sum, el| sum + el }.to_f / self.text_elements.size
    end

    def inspect
      vars = (self.instance_variables - [:@text_elements]).map{ |v| "#{v}=#{instance_variable_get(v).inspect}" }
      texts = self.text_elements.sort_by { |te| te.top }.map { |te| te.text }
      "<#{self.class}: #{vars.join(', ')}, @text_elements=#{texts.join(', ')}>"
    end

  end

  class Ruling < ZoneEntity
    # 2D line intersection test taken from comp.graphics.algorithms FAQ
    def intersects?(other)
      r = ((self.top-other.top)*(other.right-other.left) - (self.left-other.left)*(other.bottom-other.top)) \
      / ((self.right-self.left)*(other.bottom-other.top)-(self.bottom-self.top)*(other.right-other.left))

        s = ((self.top-other.top)*(self.right-self.left) - (self.left-other.left)*(self.bottom-self.top)) \
            / ((self.right-self.left)*(other.bottom-other.top) - (self.bottom-self.top)*(other.right-other.left))

      r >= 0 and r < 1 and s >= 0 and s < 1
    end

    def vertical?
      left == right
    end

    def horizontal?
      top == bottom
    end

    def to_json(arg)
      [left, top, right, bottom].to_json
    end

    def to_xml
      "<ruling x1=\"%.2f\" y1=\"%.2f\" x2=\"%.2f\" y2=\"%.2f\" />" \
      % [left, top, right, bottom]
    end

    def self.clean_rulings(rulings, max_distance=4)

      # merge horizontal and vertical lines
      # TODO this should be iterative
      horiz = rulings.select(&:horizontal?)
        .group_by(&:top)
        .values.reduce([]) { |memo, rs|
        rs.sort_by(&:left)
        memo << if rs.size > 1
                  Tabula::Ruling.new(rs[0].top, rs[0].left, rs[-1].right - rs[0].left, 0)
                else
                  rs.first
                end
      }

      vert = rulings.select(&:vertical?)
        .group_by(&:left)
        .values.reduce([]) { |memo, rs|
        rs = rs.sort_by(&:top)
        memo << if rs.size > 1
                  Tabula::Ruling.new(rs[0].top, rs[0].left, 0, rs[-1].bottom - rs[0].top)
                else
                  rs.first
                end
      }

      # - only keep horizontal rulings that intersect with at least one vertical ruling
      # - only keep vertical rulings that intersect with at least one horizontal ruling
      # yeah, it's a naive heuristic. but hey, it works.

      # h_mean =  horiz.reduce(0) { |accum, i| accum + i.width } / horiz.size
      # horiz.reject { |h| h.width < h_mean }

      #vert.delete_if  { |v| !horiz.any? { |h| h.intersects?(v) } } unless horiz.empty?
      #horiz.delete_if { |h| !vert.any?  { |v| v.intersects?(h) } } unless vert.empty?

      return { :horizontal => horiz, :vertical => vert }
    end




  end

end
