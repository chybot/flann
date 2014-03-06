class FFI::Pointer
  class << self
    def new_from_nmatrix nm
      raise(StorageError, "dense storage expected") unless nm.dense?
      ::FFI::Pointer.new(nm.data_pointer).tap { |p| p.autorelease = false }
    end
  end
end

module Flann
  class Index

    # Constructor takes a block where we set each of the parameters. We need to be careful to do this since
    # we're using the C API and not C++; so everything important needs to be initialized or there could be
    # a segfault. For reasonable default definitions, see:
    #
    # * https://github.com/mariusmuja/flann/tree/master/src/cpp/flann/algorithms
    #
    def initialize dataset = nil, dtype: :float64, parameters: Flann::Parameters::DEFAULT
      @dataset        = dataset
      @dtype          = (!dataset.nil? && dataset.is_a?(NMatrix)) ? dataset.dtype : dtype
      @index_ptr      = nil

      @parameters_ptr, @parameters = Flann::handle_parameters(parameters)

      yield @parameters if block_given?
    end
    attr_reader :dtype, :dataset, :parameters, :parameters_ptr, :index_ptr

    # Assign a new dataset. Requires that the old index be freed.
    def dataset= new_dataset
      free!
    end

    # Build an index
    def build!
      raise("no dataset specified") if dataset.nil?

      c_method = "flann_build_index_#{Flann::dtype_to_c(dtype)}".to_sym
      speedup_float_ptr = FFI::MemoryPointer.new(:float)
      @index_ptr = Flann.send(c_method, FFI::Pointer.new_from_nmatrix(dataset), dataset.shape[0], dataset.shape[1], speedup_float_ptr, parameters_ptr)

      # Return the speedup
      speedup_float_ptr.read_float
    end

    # Get the nearest neighbors based on this index. Forces a build of the index if one hasn't been done yet.
    def nearest_neighbors testset, k, parameters = {}
      parameters = Parameters.new(Flann::Parameters::DEFAULT.merge(parameters))

      self.build! if index_ptr.nil?

      parameters_ptr, parameters = Flann::handle_parameters(parameters)
      result_size = testset.shape[0] * k

      c_type = Flann::dtype_to_c(dataset.dtype)
      c_method = "flann_find_nearest_neighbors_index_#{c_type}".to_sym
      indices_int_ptr, distances_t_ptr = Flann::allocate_results_space(result_size, c_type)

      Flann.send c_method, index_ptr,
                           FFI::Pointer.new_from_nmatrix(testset),
                           testset.shape[0],
                           indices_int_ptr, distances_t_ptr,
                           k,
                           parameters_ptr

      [indices_int_ptr.read_array_of_int(result_size), distances_t_ptr.read_array_of_float(result_size)]
    end

    # Perform a radius search on a single query point
    def radius_search query, radius, parameters = {}
      max_k      = parameters[:max_neighbors] || dataset.shape[1]
      parameters = Parameters.new(Flann::Parameters::DEFAULT.merge(parameters))

      self.build! if index_ptr.nil?
      parameters_ptr, parameters = Flann::handle_parameters(parameters)

      c_type = Flann::dtype_to_c(dataset.dtype)
      c_method = "flann_radius_search_#{c_type}".to_sym
      indices_int_ptr, distances_t_ptr = Flann::allocate_results_space(max_k, c_type)

      Flann.send(c_method, index_ptr, FFI::Pointer.new_from_nmatrix(query), indices_int_ptr, distances_t_ptr, max_k, radius, parameters_ptr)

      # Return results: two arrays, one of indices and one of distances.
      [indices_int_ptr.read_array_of_int(max_k), distances_t_ptr.read_array_of_float(max_k)]
    end

    # Save an index to a file (without the dataset).
    def save filename
      raise(IOError, "Cannot write an unbuilt index") if index_ptr.nil?     # FIXME: This should probably have its own exception type.
      c_method = "flann_save_index_#{Flann::dtype_to_c(dtype)}".to_sym
      Flann.send(c_method, index_ptr, filename)
      self
    end

    # Load an index from a file (with the dataset already known!).
    #
    # FIXME: This needs to free the previous dataset first.
    def load! filename
      c_method = "flann_load_index_#{Flann::dtype_to_c(dtype)}".to_sym

      @index_ptr = Flann.send(c_method, filename, FFI::Pointer.new_from_nmatrix(dataset), dataset.shape[0], dataset.shape[1])
      self
    end

    # Free an index
    def free! parameters = {}
      parameters = Parameters.new(Flann::Parameters::DEFAULT.merge(parameters))
      c_method = "flann_free_index_#{Flann::dtype_to_c(dtype)}".to_sym
      parameters_ptr, parameters = Flann::handle_parameters(parameters)
      Flann.send(c_method, index_ptr, parameters_ptr)
      @index_ptr = nil
      self
    end

  end
end