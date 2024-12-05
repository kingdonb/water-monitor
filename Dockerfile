FROM ruby:3.3.5

# Set working directory
WORKDIR /app

# Copy the Gemfile and Gemfile.lock into the image
COPY ruby/Gemfile ruby/Gemfile.lock ./

# Install dependencies
RUN bundle install

# Copy the rest of the application code
COPY ruby/ .

# Expose the port the app runs on
EXPOSE 4567

# Command to run the application
CMD ["bundle", "exec", "ruby", "main.rb"]
