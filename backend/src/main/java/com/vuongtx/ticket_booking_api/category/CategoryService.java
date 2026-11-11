package com.vuongtx.ticket_booking_api.category;

import com.vuongtx.ticket_booking_api.category.dto.CreateCategoryRequest;
import com.vuongtx.ticket_booking_api.common.exception.DuplicateResourceException;
import com.vuongtx.ticket_booking_api.common.exception.ResourceNotFoundException;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Sort;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

@Service
@RequiredArgsConstructor
@Transactional(readOnly = true)
public class CategoryService {

    private final CategoryRepository categoryRepository;

    public List<CategoryResponse> findAll() {
        return categoryRepository.findAll(Sort.by("name"))
                .stream()
                .map(CategoryResponse::from)
                .toList();
    }

    public CategoryResponse findById(Long id) {
        return categoryRepository.findById(id)
                .map(CategoryResponse::from)
                .orElseThrow(() -> new ResourceNotFoundException("Category", id));
    }

    @Transactional
    public CategoryResponse create(CreateCategoryRequest request) {
        String name = request.name().strip();
        String description = normalize(request.description());

        if (categoryRepository.existsByNameIgnoreCase(name)) {
            throw new DuplicateResourceException("Category", "name", name);
        }

        Category saved = categoryRepository.save(new Category(name, description));
        return CategoryResponse.from(saved);
    }

    private static String normalize(String value) {
        return (value == null || value.isBlank()) ? null : value.strip();
    }
}
