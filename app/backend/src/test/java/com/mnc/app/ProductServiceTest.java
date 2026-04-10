package com.mnc.app;

import com.mnc.app.model.Product;
import com.mnc.app.repository.ProductRepository;
import com.mnc.app.service.ProductService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class ProductServiceTest {

    @Mock
    private ProductRepository productRepository;

    @InjectMocks
    private ProductService productService;

    private Product sampleProduct;

    @BeforeEach
    void setUp() {
        sampleProduct = Product.builder()
                .id(1L)
                .name("Test Product")
                .description("A test product")
                .price(new BigDecimal("99.99"))
                .stockQuantity(100)
                .build();
    }

    @Test
    void getAllProducts_shouldReturnAllProducts() {
        when(productRepository.findAll()).thenReturn(List.of(sampleProduct));
        List<Product> result = productService.getAllProducts();
        assertThat(result).hasSize(1);
        assertThat(result.get(0).getName()).isEqualTo("Test Product");
        verify(productRepository, times(1)).findAll();
    }

    @Test
    void getProductById_whenExists_shouldReturnProduct() {
        when(productRepository.findById(1L)).thenReturn(Optional.of(sampleProduct));
        Optional<Product> result = productService.getProductById(1L);
        assertThat(result).isPresent();
        assertThat(result.get().getPrice()).isEqualByComparingTo("99.99");
    }

    @Test
    void getProductById_whenNotExists_shouldReturnEmpty() {
        when(productRepository.findById(999L)).thenReturn(Optional.empty());
        Optional<Product> result = productService.getProductById(999L);
        assertThat(result).isEmpty();
    }

    @Test
    void createProduct_shouldSaveAndReturnProduct() {
        when(productRepository.save(any(Product.class))).thenReturn(sampleProduct);
        Product result = productService.createProduct(sampleProduct);
        assertThat(result.getId()).isEqualTo(1L);
        verify(productRepository, times(1)).save(sampleProduct);
    }

    @Test
    void updateProduct_whenExists_shouldUpdateAndReturn() {
        Product updated = Product.builder()
                .name("Updated Product")
                .description("Updated desc")
                .price(new BigDecimal("149.99"))
                .stockQuantity(50)
                .build();
        when(productRepository.findById(1L)).thenReturn(Optional.of(sampleProduct));
        when(productRepository.save(any(Product.class))).thenReturn(sampleProduct);
        Optional<Product> result = productService.updateProduct(1L, updated);
        assertThat(result).isPresent();
        verify(productRepository, times(1)).save(any(Product.class));
    }

    @Test
    void updateProduct_whenNotExists_shouldReturnEmpty() {
        when(productRepository.findById(999L)).thenReturn(Optional.empty());
        Optional<Product> result = productService.updateProduct(999L, sampleProduct);
        assertThat(result).isEmpty();
        verify(productRepository, never()).save(any());
    }

    @Test
    void deleteProduct_whenExists_shouldReturnTrue() {
        when(productRepository.existsById(1L)).thenReturn(true);
        doNothing().when(productRepository).deleteById(1L);
        boolean result = productService.deleteProduct(1L);
        assertThat(result).isTrue();
        verify(productRepository, times(1)).deleteById(1L);
    }

    @Test
    void deleteProduct_whenNotExists_shouldReturnFalse() {
        when(productRepository.existsById(999L)).thenReturn(false);
        boolean result = productService.deleteProduct(999L);
        assertThat(result).isFalse();
        verify(productRepository, never()).deleteById(any());
    }

    @Test
    void searchByName_shouldReturnMatchingProducts() {
        when(productRepository.findByNameContainingIgnoreCase("laptop"))
                .thenReturn(List.of(sampleProduct));
        List<Product> result = productService.searchByName("laptop");
        assertThat(result).hasSize(1);
    }
}
