file(GLOB nows_HDRS "${CMAKE_CURRENT_SOURCE_DIR}/*.h")

set(nows_SRCS
	${nows_HDRS}
	${CMAKE_CURRENT_SOURCE_DIR}/nows_fft.cpp
	${CMAKE_CURRENT_SOURCE_DIR}/nows_field.cpp
	${CMAKE_CURRENT_SOURCE_DIR}/nows_fno.cpp
	${CMAKE_CURRENT_SOURCE_DIR}/nows_manager.cpp
	${CMAKE_CURRENT_SOURCE_DIR}/nows_model.cpp
	${CMAKE_CURRENT_SOURCE_DIR}/nows_validation.cpp
	PARENT_SCOPE
)